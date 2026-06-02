# TODOs
- [ ] Multiple AI models comparison
- [ ] Training to think like IPBES???
- [x] one generation (CONF INTERPRET)
- [ ] not rewrite, but flag.
- [ ] Gaps: Same pipeline, in CONF DATA (the one we have)
- [x] Users: GA2 Ch 1 authors, IPBES, other assessments
- [x] use openrouter:
  - [x] API_openrouter
  - [x] https://ellmer.tidyverse.org/reference/chat_openrouter.html
- [x] Change local fuseka serer to one endpoint for ALL assessments.


- [x] `truth` should be a structured prompt. 
  - One `truth` prompt per KM/BM
  - There can be multiple submessage sections (one per submessage of the KM/BM))
  - source is only for that respective section ( KM/BM, submessage)
  - it is possible, that a source occurs multiple times (can this be avoided?)
  - format json instead of markdown?



# Prompt implementation of AI assessment

## Setup

Next step is to compare the `truth` KMs with the `citing`. For this an AI will be use ellmer. The comparison should determine if the papers from the snowwball search contradict or support the KM (details later on the output format).
`ellmer` package should be used and openrouter be the backend. Default should be a free model.
The Openrouter modell should be specified in the config file. It should be possible that more then one model is specified, and the results should be similarly be handled as the assessments, i.e. invalidate only if a model is removed or replaced. If on e is added, simply the new model should run.

## Answer Structure

The result should be structured, and contain the following fields:

- lm_id: id if the key message
- work_id: OpenAlex id of the work the KM is compared to
- km_message: the in max 20 words distilled key message
- work_alignement: value from -5 to +5, where -5 is strong contradiction, 0 is neutral and +5 strong support
- confidence: the confidence of the work_alignement
- evidence: section from the work which underlines the work_alignement (max 100 words)
- justification: justification for the work_alignement (max 100 words)


