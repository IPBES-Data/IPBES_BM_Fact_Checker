# Reviewer guide — IPBES claim/paper verdicts

You have a file called `R1_<assessment>.csv` or `R2_<assessment>.csv`. Each row
pairs one **claim** taken from an IPBES assessment with one **paper** (title and
abstract). Your job is to fill in the `verdict` column.

There are two of you, working **independently**. Please do not discuss
individual rows until both files are finished. We measure how often you agree,
and that number is only meaningful if the judgements were made separately.

## What the labels mean

Fill `verdict` with exactly one of these four words.

**`SUPPORTS`** — the abstract contains a finding that makes the claim *more
likely to be true*. The paper does not have to prove the claim, cover all of it,
or use the same words. It does have to report something that bears on it.

**`REFUTES`** — the abstract contains a finding that makes the claim *less
likely to be true*: a contrary result, a reversed direction of effect, a failure
to find what the claim asserts.

**`NOT_ENOUGH_INFO`** — you have read the abstract and it does not settle the
claim either way. This is the correct answer for most rows, and it is a real
judgement, not a fallback. It covers:

- the paper is on a related topic but reports nothing that bears on this claim;
- the abstract is descriptive or methodological and reports no finding;
- the finding is about a different taxon, region, driver or timescale than the
  claim, so it cannot be carried over.

**`CANNOT_JUDGE`** — something is wrong with the *row*, not with the paper. Use
it when the abstract is not in English, is truncated or garbled, is clearly not
an abstract, or when the claim is too fragmentary or ambiguous to be assessed at
all. Please say which in `note`.

`CANNOT_JUDGE` is deliberately separate from `NOT_ENOUGH_INFO`. The first means
"you cannot ask me this"; the second means "I read it, and it does not answer
the question". Folding one into the other would hide a problem with how the
material was assembled.

## Three rules that matter more than they look

**1. Judge only from the abstract in front of you.** Not from the full paper,
not from what you know about the topic, not from what you know about the authors.
If the abstract does not say it, it is not there. This is the hardest rule to
follow and the most important: the system being evaluated sees exactly this text
and nothing else, so judging on extra knowledge measures the wrong thing.

**2. Being on-topic is not support.** A paper can be squarely about the right
subject and still report nothing that bears on the specific claim. This is the
single most common error, and it is the specific failure we are trying to
measure — so a row that feels "obviously relevant" deserves a second look before
you write `SUPPORTS`.

**3. Judge the whole claim.** Some claims bundle several assertions, or attach a
mechanism to an observation. If the abstract supports one part and says nothing
about the rest, that is `NOT_ENOUGH_INFO`, not `SUPPORTS`. Note which part it
did address.

## Filling in the file

| column | what to put |
|---|---|
| `verdict` | one of the four words above — **required** |
| `note` | free text; always worth a line when you hesitated, and required for `CANNOT_JUDGE` |
| `reviewer` | your initials — same value on every row |
| `date` | the date you judged the row, `YYYY-MM-DD` |

Edit `verdict`, `note`, `reviewer` and `date` only. Please do not reorder, add
or delete rows, and do not change `id` — the two files are matched on it. The
row order differs between the two of you on purpose.

The file is plain CSV. If you open it in Excel, save it back as CSV (UTF-8), not
as `.xlsx`.

## Pace, and when to stop

Expect around 1.5 minutes per row, so roughly five hours for 200 rows. Please
spread it over several sittings — agreement drops measurably when reviewers
tire, and the comparison is between the two of you.

If you find yourself unsure for more than a minute or so, write the verdict you
lean towards and say so in `note`. A recorded hesitation is more useful than a
confident guess, and disagreements between you are something we want to see, not
something to avoid.

## What happens next

The two files are compared row by row. Rows where you agree become the gold
standard that every model is scored against. Rows where you disagree are
reported as the *human ceiling* — the limit of how well any automated system
could be expected to do — and are not used to score models.
