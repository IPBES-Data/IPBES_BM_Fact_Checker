# Reviewer guide — IPBES claim/paper verdicts

You have two Excel workbooks, one per set: `R1_GA1_A_template.xlsx` (240 rows)
and `R1_GA1_B_template.xlsx` (99 rows) — or the same with `R2`. Each row of a
workbook's Review sheet pairs one **claim** taken from an IPBES assessment with
one **paper** (title and abstract). Your job is to fill in the `verdict` column.
The two sets are judged in exactly the same way, with the same rules.

There are two of you, working **independently**. Please do not discuss
individual rows until both of you have finished both workbooks. We measure how often you agree,
and that number is only meaningful if the judgements were made separately.

## What the labels mean

Fill `verdict` with exactly one of these four words.

**`SUPPORTS`** — the abstract contains a finding that makes the claim *more
likely to be true*. The paper does not have to prove the claim, cover all of it,
or use the same words. It does have to report a finding that bears on it. A
finding on **one part** of a claim (rule 3), or for **one region, taxon, time
period or scale** (rule 5), is enough — unless something in the abstract
refutes the claim, in which case it is `REFUTES`.

**`REFUTES`** — the abstract contains a finding that makes the claim *less
likely to be true*: a contrary result, a reversed direction of effect, a failure
to find what the claim asserts.

> **A contradiction does not have to be total.** Most IPBES claims are
> generalisations — "X is declining", "Y drives Z". A paper that reports the
> opposite **for one region, taxon, time period or scale** makes a general claim
> less likely to be true, and that is `REFUTES`, not `NOT_ENOUGH_INFO`. Say in
> `note` how far the contradiction reaches ("only for boreal systems", "only
> 1990–2005"). Use `NOT_ENOUGH_INFO` when the paper simply does not speak to the
> claim — not when it speaks to part of it and disagrees.
>
> This matters because we are specifically measuring whether the system finds
> refutations at all. Earlier rounds produced almost none, and partial
> contradictions being filed as `NOT_ENOUGH_INFO` was the main reason.

**`NOT_ENOUGH_INFO`** — you have read the abstract and it reports **no finding
that bears on the claim, in either direction** — not even on one part of it or
for one region. This is the correct answer for many rows, and it is a real
judgement, not a fallback. It covers:

- the paper is on a related topic but reports nothing that bears on this claim;
- the abstract only *mentions* the claim's topic or one of its listed items,
  without reporting a finding on it;
- the abstract is descriptive or methodological and reports no finding;
- the finding concerns a different taxon, region, driver or timescale **and
  nothing in it points either way** on the claim as stated.

On that last point: a result from outside the claim's scope that simply *does
not reach* the claim is `NOT_ENOUGH_INFO`, but a result from inside part of the
claim's scope is not — it is `SUPPORTS` if it agrees and `REFUTES` if it runs
against it. "Different scope" or "only part of the claim" is not by itself a
reason to withhold a verdict.

**`CANNOT_JUDGE`** — something is wrong with the *row*, not with the paper. Use
it when the abstract is not in English, is truncated or garbled, is clearly not
an abstract, or when the claim is too fragmentary or ambiguous to be assessed at
all. Please say which in `note`.

`CANNOT_JUDGE` is deliberately separate from `NOT_ENOUGH_INFO`. The first means
"you cannot ask me this"; the second means "I read it, and it does not answer
the question". Folding one into the other would hide a problem with how the
material was assembled.

## Quick decision table

Work down the table; the **first** row that applies is the verdict. The rules
below explain each row.

| # | What the abstract does | Verdict |
|--|------------------------------------------|------------|
| 1 | Row is unusable: not English, truncated, not an abstract, or the claim is unintelligible | `CANNOT_JUDGE` |
| 2 | Reports a finding **against any part** of the claim, or against it **in any region, taxon or period** — whatever else it supports | `REFUTES` |
| 3 | Reports a finding **for the whole claim** | `SUPPORTS` |
| 4 | Reports a finding **for one part** of the claim (e.g. one item of a list), the rest untouched | `SUPPORTS` |
| 5 | Reports a finding **for one region, taxon or period** of a general claim | `SUPPORTS` |
| 6 | Only **mentions** the claim's topic or a listed item, without reporting a finding on it | `NOT_ENOUGH_INFO` |
| 7 | On topic, but reports **no finding** (descriptive, methodological, background) | `NOT_ENOUGH_INFO` |
| 8 | Finding is about something else, or outside the claim's scope **and points neither way** | `NOT_ENOUGH_INFO` |

In short: a refutation anywhere wins; otherwise any real finding in the claim's
direction — on one part or for one place — is `SUPPORTS`; no finding is
`NOT_ENOUGH_INFO`.

## Five rules that matter more than they look

**1. Judge only from the title and abstract in front of you.** Not from the
full paper, not from what you know about the topic, not from what you know about
the authors — which is also why the workbook gives no DOI or link. If the title
and abstract do not say it, it is not there. This is the hardest rule to follow
and the most important: the system being evaluated sees exactly this text and
nothing else, so judging on extra knowledge measures the wrong thing.

**2. Being on-topic is not support.** A paper can be squarely about the right
subject and still report nothing that bears on the specific claim. This is the
single most common error, and it is the specific failure we are trying to
measure — so a row that feels "obviously relevant" deserves a second look before
you write `SUPPORTS`.

**3. Parts of a claim: one is enough — and REFUTES wins.** Many claims bundle
several assertions, attach a mechanism to an observation, or list several items.

- A finding on **one** part, in the claim's direction, is `SUPPORTS` — even if
  the abstract says nothing about the other parts or the rest of a list.
- A finding against **any** part is `REFUTES`, whatever else the abstract says.
- A paper that supports one part and contradicts another is `REFUTES`.

Name the part in `note`. Merely *mentioning* a listed item, without reporting a
finding on it, is still `NOT_ENOUGH_INFO` (rules 2 and 4).

**4. The `SUPPORTS` / `NOT_ENOUGH_INFO` line.** This is where reviewers and
models disagree most, so one test to apply consistently: *would someone writing
this claim have been able to cite this paper for it?* If the abstract reports a
result you could put in a bracket after the sentence, it is `SUPPORTS`. If you
would be citing it for background, framing or an adjacent fact, it is
`NOT_ENOUGH_INFO`. Agreement in the same direction is not support — the paper
must report a **finding**, not merely a compatible view.

**5. Scope: one region is enough, either way — and REFUTES wins.** Rule 3 is
about the claim's *parts*; this rule is about its *scope* (where, what, when).
The principle is the same: one part or one place is enough, and a contradiction
anywhere wins.

- A finding that agrees with a general claim **for one region, taxon, time
  period or scale** is `SUPPORTS`.
- A finding that runs against it for one region, taxon, period or scale is
  `REFUTES`.
- A paper that reports **both** — supporting in one region, contrary in another
  — is `REFUTES`. Name the contrary part in `note`.

In both cases say in `note` how far the finding reaches ("only boreal",
"only 1990–2005").

## Filling in the file

The workbook opens on an Instructions sheet; this guide is repeated on the
Guide sheet. The rows are on the Review sheet.

| column | what to put |
|---|---|
| `verdict` | one of the four words above, chosen from the dropdown — **required** |
| `note` | free text; always worth a line when you hesitated, and required for `CANNOT_JUDGE` |

Only the yellow `verdict` and `note` cells can be edited; everything else is
locked, and an empty verdict (or a `CANNOT_JUDGE` without a note) stays
highlighted until you fill it. Put your initials once, on the Instructions
sheet. The row order differs between the two of you on purpose — your workbook
and the other reviewer's are matched on `id`.

When you are done with a workbook, save it under the same name without
`_template` (e.g. `R1_GA1_A.xlsx`; its Instructions sheet gives your exact name)
and keep it as `.xlsx`. Send back both: `R1_GA1_A.xlsx` and `R1_GA1_B.xlsx` (or
the `R2` pair).

## Pace, and when to stop

Expect around 1.5 minutes per row, so roughly eight and a half hours for the
339 rows of both workbooks together (six hours for set A, two and a half for
set B). Please
spread it over several sittings — agreement drops measurably when reviewers
tire, and the comparison is between the two of you.

If you find yourself unsure for more than a minute or so, write the verdict you
lean towards and say so in `note`. A recorded hesitation is more useful than a
confident guess, and disagreements between you are something we want to see, not
something to avoid.

## What happens next

Your workbooks and the other reviewer's are compared row by row, set by set.
Rows where you agree become the gold
standard that every model is scored against. Rows where you disagree are
reported as the *human ceiling* — the limit of how well any automated system
could be expected to do — and are not used to score models.
