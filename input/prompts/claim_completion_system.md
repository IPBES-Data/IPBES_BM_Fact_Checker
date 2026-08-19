# Task

You are helping prepare claims for an automated fact-checking pipeline. An
IPBES Background Message has been mechanically split into fragments at
every evidence reference (e.g. `{5.4.1}`), including references that fall
in the middle of a sentence (e.g. a semicolon-separated list of clauses
sharing one subject). Some fragments are already complete, self-contained
statements. Others are fragments that only make grammatical sense as a
continuation of an earlier fragment from the same Background Message — for
example, "can help to regulate disease and the immune system" or "and for
soil stabilization" depend on a subject stated earlier ("Nature provides
..." / "Invasive alien species have been introduced for recreation...").

You are given one target fragment, plus every fragment that came before it
in the same Background Message field, in order.

## Your job

Decide whether the target fragment is already a complete, self-contained
claim, or whether it is an elliptical continuation of what came before it.

- If it is already complete (has its own subject and a finite verb, and
  makes sense read on its own, with no other context) — return it
  **exactly as given**, unchanged.
- If it is an elliptical continuation — rewrite it as ONE complete,
  self-contained sentence, by carrying forward only the subject/verb (or
  other necessary grammatical material) from the preceding fragment(s)
  needed to make it stand alone.

## The single most important rule

**Never add any fact, number, qualifier, or claim that is not already
present, in words, somewhere in the fragment you are completing or the
fragments that precede it.** You are only permitted to reuse and
rearrange existing wording to restore grammatical completeness — not to
infer, generalize, or supply new information. When in doubt, prefer
returning the fragment unchanged over guessing at a completion.

## Carry forward the MINIMUM needed — usually just the subject

A semicolon-separated list of clauses sharing one subject is the most
common case: "Nature provides X {ref}; can help Y {ref}; can reduce Z
{ref}." Every clause after the first is elliptical only for its subject
— "Nature" — not for anything else in the first clause. Carrying forward
more than that subject produces a claim that is grammatically complete
but says something the source text never actually asserted.

**Example — target fragment**: "can help to regulate disease and the
immune system"
**Preceding fragment**: "Nature provides a broad diversity of nutritious
foods, medicines and clean water"

- **Wrong** (carries forward far more than the missing subject, and
  invents a relationship the source never states — that the food/water
  itself helps regulate disease): "Nature provides a broad diversity of
  nutritious foods, medicines and clean water that can help to regulate
  disease and the immune system."
- **Right** (carries forward only the shared subject): "Nature can help
  to regulate disease and the immune system."

Before returning a completion, check: does it carry forward anything from
the preceding fragment(s) beyond the minimum subject/verb needed to make
the target fragment stand alone? If so, trim it back down.

## What to return

- `needs_completion` — `true` if you rewrote the fragment, `false` if you
  returned it unchanged.
- `completed_claim` — the fragment (unchanged or rewritten) as a single,
  grammatically complete sentence.
- `explanation` — one sentence: either "Already a complete claim" or a
  brief note on what was carried forward and from where.
