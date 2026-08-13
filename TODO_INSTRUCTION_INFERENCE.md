# Instruction-tuned embeddings as a post-NLI grouping stage

Status: **idea, not scheduled.** Recorded so the reasoning is not lost. Nothing in
the pipeline depends on it.

## The short version

Use an instruction-tuned text embedder **after** NLI has scored everything, to
group the works *within* each label class by **how** they bear on the claim. Not
as a retriever in front of NLI, and emphatically not as a replacement for it.

```
claim × all premises ──[NLI]──► supports / refutes / is not relevant to
                                        │
                                        ├─ within "supports":  group by mechanism
                                        └─ within "refutes":   group by scope condition
                                                 ▲
                                     instruction-tuned embedder
```

## Why not use the embedder for the verification itself

Worth stating explicitly, because it is the tempting misuse.

Cosine similarity is **symmetric**; entailment is **directional**. "A poodle is in
the garden" entails "a dog is in the garden" but not the reverse, and no metric
satisfying `sim(A,B) = sim(B,A)` can express that.

Worse, embedders handle **negation** poorly. *"Global pollinator abundance
declined"* and *"Global pollinator abundance did not decline"* share almost every
token, the same entities and the same topic, so they sit almost on top of each
other in embedding space — while being exactly contradictory. Fact-checking is
precisely the task where a claim and its negation must be told apart. The same
applies to magnitude: *"declined by 5%"* and *"declined by 50%"* are near-identical
vectors and different facts.

The structural reason: an embedder is a **bi-encoder** — claim and premise are
encoded separately and never see each other, only their vectors are compared. The
NLI model is a **cross-encoder**: both texts go in together, so it can attend from
the *not* in one to the corresponding span in the other. That interaction is what
entailment needs and is unavailable to a bi-encoder. It is not a training gap that
a better instruction can close.

## Why not use it as a retriever in front of NLI either

The standard architecture elsewhere is retrieve-then-verify, because NLI is too
expensive to run over a whole corpus. **This pipeline already runs NLI over every
(claim, premise) pair**, which buys something a retrieval filter destroys:
complete recall.

That matters here more than usual. If a top-k retriever misses the one abstract
that refutes a key message, the pipeline reports "no contradicting evidence found"
— which reads identically to "the message is well supported". Similarity-based
retrieval is also biased toward *confirming* evidence, because a supporting
passage tends to share more vocabulary with the claim than a refuting one does.
Keep the exhaustive scoring.

## What the embedder is actually good for here

After NLI, every work carries a label and a score. What is missing is any
structure *across* works. If 200 abstracts support a key message, the output is a
list, not an understanding.

Because the grouping happens **within one label class**, everything in the pool
already has the same polarity — so the negation weakness above never arises. NLI
has settled direction; the embedder is only asked to organise a homogeneous set,
which is what similarity is genuinely good at.

Three things it would add:

1. **Distinct arguments rather than repetitions.** Many works make the same point.
   Collapsing near-duplicates shows the *breadth* of support rather than its
   *volume* — different things, easily confused when counting papers, and the
   distinction a reviewer actually needs.
2. **Structure in the disagreement.** If the `refutes` set splits cleanly by
   region, taxon, biome or period, that is often the real finding: the message
   holds conditionally rather than being simply supported or not.
3. **A representative per group**, so a reviewer reads one abstract per line of
   evidence instead of all 200.

## Design decisions that need deciding, not defaulting

### What text to embed

The premise column currently holds a whole abstract. Options, sharpest first:

- **The sentence(s) NLI keyed on** — sharpest, but `score_one_claim()` does not
  currently record which span drove the label, so this needs the scorer to return
  it (or a separate sentence-level pass).
- **The whole premise abstract** — available today, no changes, but the vector is
  dominated by whatever the abstract is mostly about rather than by its relation
  to the claim.

### Claim-conditional or claim-independent

This is the consequential one, because it decides the cost.

- **Claim-conditional** (claim inside the instruction): the same abstract gets a
  different vector for every claim, which is exactly the aspect-shift wanted — but
  it cannot be pre-computed or indexed, so the embedding cost becomes
  O(claims × works), the same order as NLI itself.
- **Claim-independent** (embed the premise once, claim not referenced): indexable
  and reusable across every claim and assessment, far cheaper, but the grouping
  reflects general similarity rather than similarity *with respect to this claim*.

Suggested compromise: start claim-**independent** on the `refutes` sets only. They
are small, and they are where the interpretive payoff is highest. Only pay for
claim-conditional embeddings if the cheap version visibly fails to separate.

### Grouping method

Number of clusters and algorithm are **analyst degrees of freedom**. If the
grouping is ever going to appear in a result rather than serve as a browsing aid,
it needs the same treatment as any other such choice: recorded in config, and its
sensitivity to that choice reported. A similarity map for review carries no such
burden — worth deciding up front which of the two this is.

## Example instructions

Instruction-tuned embedders take a short task description alongside the text. The
exact template is **model-specific** — E5 wants `query:` / `passage:` prefixes,
BGE and GTE want an `Instruct:` line — so treat these as content, not as literal
syntax, and check the model card.

**Grouping the `supports` set by mechanism** (claim-conditional):

```
Instruct: The passage below supports the given claim. Represent the specific
mechanism, taxon, region or line of evidence through which it does so, such that
passages supporting the claim for the same reason are close together and passages
supporting it for different reasons are far apart.
Claim: {claim}
Passage: {premise}
```

**Grouping the `refutes` set by scope condition** (claim-conditional):

```
Instruct: The passage below contradicts or qualifies the given claim. Represent
the reason or the scope condition under which it does so — the system, region,
time period or method that makes the claim fail — such that passages failing the
claim for the same reason group together.
Claim: {claim}
Passage: {premise}
```

**De-duplicating evidence** (claim-independent, indexable, reusable):

```
Instruct: Represent the substantive empirical finding reported in this passage,
such that passages reporting the same finding about the same system are close
together, regardless of wording.
Passage: {premise}
```

Note how the third differs in kind: it never mentions the claim, so one vector per
work serves every claim in every assessment. That is the version to try first.

### The instruction is a research degree of freedom

"Represent the mechanism" and "represent the theoretical commitment" will give
different groupings, with no principled way to choose between them. If this is
implemented, the instruction string belongs in `input/` under version control and
in the cache key — the same discipline the NLI `candidate_labels` and the LLM
prompts already get. A prompt that lives only in a function body is a silent
analytical choice.

## Implementation sketch

Nothing here is committed to; this is the shape it would take.

1. **Serving.** Embeddings via a HuggingFace TEI server, as in the sibling
   `Categorisation_Literature` project (`scripts/start_tei_specter2.sh` is the
   pattern), or the RunPod route already used here. Note that the strong
   instruction-tuned models are ~7B parameters against SPECTER2's ~110M, so this
   is GPU territory rather than Metal-on-a-laptop.
2. **Do NOT reuse SPECTER2 for this.** It is citation-trained, so its geometry is
   organised by topic and citation community — it would group works by subject
   area, which is close to what we already know and not what is being asked.
3. **New targets**, alongside the existing NLI scores rather than replacing
   anything:
   - `nli_evidence_embeddings` — one vector per (work, label class), or per
     (claim, work, label class) if claim-conditional
   - `nli_evidence_groups` — group assignment plus a representative member
   - a figure or table per key message showing the grouped evidence
4. **Validation.** The grouping must be checked, not trusted: read the members of
   several groups and confirm they share what the instruction asked for. Without
   that step this produces confident-looking clusters of nothing in particular.

## Related

- `NEXT_STEPS.md` — NLI hypothesis-length work; unrelated but same pipeline stage.
- `R/score_one_claim.R` — where `supports` / `refutes` / `is not relevant to` are
  assigned, and where a "which span drove the label" field would have to come
  from.
- `R/build_nli_ready_parquet.R`, `R/build_nli_ready_evidence_parquet.R` — the two
  claim segmentations; both feed the same downstream targets, so this stage would
  work with either unchanged.
