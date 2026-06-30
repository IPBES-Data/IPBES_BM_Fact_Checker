"""Minimal zero-shot NLI inference server for the IPBES BM fact-checker.

Wraps a single HuggingFace ``zero-shot-classification`` pipeline behind a tiny
FastAPI app. One pipeline instance is held for the process lifetime; the model
is baked into the image at build time (see ``download_model.py`` +
``Dockerfile``), so there is no first-request download.

Endpoints
---------
GET  /health   -> {"status": "ok", "model": "..."}
GET  /metrics  -> Prometheus-style text; exposes ``nli_request_count`` so the
                  idle watchdog can detect inactivity (mirrors TEI).
POST /classify -> body:
    {
      "sequences": ["title + abstract", ...],   # premises
      "candidate_labels": ["supports", "refutes", "is not relevant to"],
      "hypothesis_template": "This paper {} the following claim: <BM text>",
      "multi_label": false,
      "batch_size": 32
    }
  returns one {"labels": [...], "scores": [...]} object per input sequence
  (labels sorted by descending score, as the HF pipeline returns them).

Tuning via env vars (all optional):
  NLI_MODEL        model id (default: MoritzLaurer/deberta-v3-large-zeroshot-v2.0)
  NLI_PORT         listen port (default: 8080)
  NLI_DEVICE       device index; -1 = CPU (default: 0 if CUDA available else -1)
  NLI_MAX_LENGTH   tokenizer truncation length (default: 512)
"""

import os
from typing import List, Optional

from fastapi import FastAPI
from pydantic import BaseModel

import torch
from transformers import pipeline

MODEL_ID = os.environ.get(
    "NLI_MODEL", "MoritzLaurer/deberta-v3-large-zeroshot-v2.0"
)
MAX_LENGTH = int(os.environ.get("NLI_MAX_LENGTH", "512"))


def _resolve_device() -> int:
    env = os.environ.get("NLI_DEVICE")
    if env is not None and env != "":
        return int(env)
    return 0 if torch.cuda.is_available() else -1


DEVICE = _resolve_device()

app = FastAPI(title="nli-runpod", version="0.1.0")

# Cumulative count of classified sequences, exposed at /metrics for the
# idle watchdog (a request that classifies N sequences increments by N).
_request_count = 0

_classifier = pipeline(
    "zero-shot-classification",
    model=MODEL_ID,
    device=DEVICE,
)


class ClassifyRequest(BaseModel):
    sequences: List[str]
    candidate_labels: List[str]
    hypothesis_template: str = "This example is {}."
    multi_label: bool = False
    batch_size: int = 32


class ClassifyResult(BaseModel):
    labels: List[str]
    scores: List[float]


@app.get("/health")
def health():
    return {"status": "ok", "model": MODEL_ID, "device": DEVICE}


@app.get("/metrics")
def metrics():
    from fastapi.responses import PlainTextResponse

    body = (
        "# HELP nli_request_count Cumulative sequences classified.\n"
        "# TYPE nli_request_count counter\n"
        f"nli_request_count {_request_count}\n"
    )
    return PlainTextResponse(body)


@app.post("/classify", response_model=List[ClassifyResult])
def classify(req: ClassifyRequest):
    global _request_count

    if not req.sequences:
        return []

    out = _classifier(
        req.sequences,
        candidate_labels=req.candidate_labels,
        hypothesis_template=req.hypothesis_template,
        multi_label=req.multi_label,
        batch_size=req.batch_size,
        truncation=True,
        max_length=MAX_LENGTH,
    )

    # The pipeline returns a single dict for one input, a list for many.
    if isinstance(out, dict):
        out = [out]

    _request_count += len(out)

    return [
        ClassifyResult(labels=list(o["labels"]), scores=[float(s) for s in o["scores"]])
        for o in out
    ]
