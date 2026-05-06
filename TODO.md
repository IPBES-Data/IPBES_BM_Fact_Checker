# TODOs
- Multiple AI models comparison
- Training to think like IPBES???
- one generation (CONF INTERPRET)
- not rewrite, but flag.
- Gaps: Same pipeline, in CONF DATA (the one we have)
- Users: GA2 Ch 1 authors, IPBES, other assessments
- use openrouter:
  - API_openrouter
  - https://ellmer.tidyverse.org/reference/chat_openrouter.html

# Prompt implementation of AI assessment

Next step is to compare the KMs with the references from the results from the snowball search which are `citing` the key paper as well as `keypaper` them selves. For this an AI will be used via ellmer to compare the key message (km) selected in the config file. The comparison should determine if the papers from the snowwball search contradict or support the KM (details later on the output format).
`ellmer` package should be used and openrouter be the backend. Default should be a free model.
The Openrouter modell should be specified in the config file. It should be possible that more then one model is specified, and the results should be similarly be handled as the assessments, i.e. invalidate only if a model is removed or replaced. If on e i=s added, simply the new model should run.
The result should be structured, and contain the following fields:

- lm_id: id if the key message
- work_id: OpenAlex id of the work the KM is compared to
- km_message: the in max 20 words distilled key message
- work_alignement: value from -5 to +5, where -5 is strong contradiction, 0 is neutral and +5 strong support
- confidence: the confidence of the work_alignement
- evidence: section from the work which underlines the work_alignement (max 100 words)
- justification: justification for the work_alignement (max 100 words)

The assessment should be done based on the title and abstract.

At a later stage, it is planned to expand this to the full text, either the pdf or the xml asw returned from OpenAlex, or the pdf provided manually in a folder - but this is the next step.

Add this as an additional target, save the results in an `output/alignement` parquet database, partitioned in the same manner as the `snowball/nodes` `citing` and `keypaper` is partitioned, without the bm partitioning and an added final `model` partitioning as well as `temperature` and "replicate. 
`replicates` is how often the assessment should be done. When the number of replicates in the config changes, all replicates should be deleted.

Config:

```
analysis:
  - assessment_id: IAS
    km: ["KM-4a", KM-B1]
    runs:
      - model: ddd
        temperature: 0
        replicates: 5

- assessment_id: GA1
    km: ["KM-4", "KM-B"]
    runs:
      - model: ddd
        temperature: 0
        replicates: 1
      - model: ccc
        temperature: 0
        replicates: 2
      - model: ddd
        temperature: 0.7
        replicates: 3 
```

the openrouter API key should be read from the environmental variable `API_openrouter`

The prompts (system as well as user prompts) should be read from the files `input/prompts/....md` Please populate these with suggested prompts - I will tune them after that.

Suggest the most efficient approach (Include progress indicators as this will be long running!) 

Provide some feedback and suggestions before developing the plan for the implementation.

Provide an argument in the target which limits the number of works to be analysed and set it initially to 20, which should include 20% keypaper and the rest the citing works.

