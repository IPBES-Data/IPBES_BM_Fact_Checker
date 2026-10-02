# TEST IMAGE: the IPBES fine-tuned NLI model, baked on top of the stock server.
#
# WHY A SEPARATE DOCKERFILE rather than the submodule's own --build-arg NLI_MODEL
# route: that route downloads the model from HuggingFace at build time, and the
# fine-tuned weights are not on HuggingFace yet (the token in the keyring is
# fine-grained with inference.serverless.write only -- no repo write). This
# overlay reaches the same end state by copying the checkpoint off disk instead.
#
# server.py resolves NLI_MODEL with AutoModelForSequenceClassification
# .from_pretrained(), which accepts a LOCAL DIRECTORY as readily as a Hub id, so
# pointing it at a baked path needs no code change. The path is inside the image
# rather than on a mounted volume deliberately -- populate_global_volume.sh
# records that NLI_MODEL pointing at /workspace breaks at pod boot, because the
# volume is not mounted when the server starts.
#
# WHAT THIS DOES NOT TEST: the BuildKit --secret path in the submodule's
# Dockerfile, which is how a private Hub model would really be baked. That still
# needs a HuggingFace token with repo write access.
#
# Build (from the repo root):
#   docker buildx build --platform linux/amd64 \
#     -f docker/ipbes-ft/Dockerfile \
#     -t ghcr.io/rkrug/nli-runpod-bge-m3-ipbes-ft:v0.5.0-GA1-512-m1 \
#     --build-arg BASE=ghcr.io/rkrug/nli-runpod-bge-m3-ipbes-ft:base-tmp .
ARG BASE=ghcr.io/rkrug/nli-runpod-bge-m3-ipbes-ft:base-tmp
FROM ${BASE}

# The checkpoint. Copied to a fixed path under /opt so it is present before the
# entrypoint runs and independent of any volume that may or may not be attached.
COPY output/nli_training_finetuned/KP=GA1/citing=GA1/downsample_seed=13/max_length=512/date=2026.09.29_14_48/best/ /opt/models/ipbes-bm-nli-atomic-ga1-512-v1/

ENV NLI_MODEL=/opt/models/ipbes-bm-nli-atomic-ga1-512-v1

# MUST match what the checkpoint was trained at. A model trained at 512 and
# served at 2048 raises nothing -- it just scores worse, quietly. The stock
# image defaults to 2048, so this override is not optional here.
ENV NLI_MAX_LENGTH=512

# Provenance, same keys the submodule's Dockerfile sets, so `docker inspect`
# answers "what is inside this" the same way for both build routes.
LABEL io.rkrug.runpod.nli.model=ipbes-bm-nli-atomic-ga1-512-v1 \
      io.rkrug.runpod.nli.model_revision=2026.09.29_14_48 \
      io.rkrug.runpod.nli.trained_assessments=GA1 \
      io.rkrug.runpod.nli.granularity=atomic_bm \
      io.rkrug.runpod.nli.max_length=512
