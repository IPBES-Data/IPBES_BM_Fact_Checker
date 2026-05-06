# Assessment context

Assessment id: `{{ASSESSMENT_ID}}`
Key Message id: `{{KM_ID}}`

## Key Message

Label: `{{KM_LABEL}}`

Description: `{{KM_DESCRIPTION}}`

## Candidate paper

Work id: `{{WORK_ID}}`
Relation in snowball search: `{{WORK_RELATION}}`
Title:

`{{WORK_TITLE}}`

Abstract:

`{{WORK_ABSTRACT}}`

## Task

Compare the candidate paper to the Key Message using only the title and abstract above.

Return a structured answer with exactly these fields:

- `lm_id`
- `work_id`
- `km_summary`
- `work_alignement`
- `confidence`
- `evidence`
- `justification`

Important:

- `lm_id` must equal `{{KM_ID}}`
- `work_id` must equal `{{WORK_ID}}`
- `work_alignement` must be an integer from -5 to +5
- `confidence` must be a number from 0 to 1
- `km_summary` must be a distilled version of the Key Message label and description, in 20 words or fewer
- if the description is empty, use the label alone for `km_summary`
- keep `evidence` and `justification` concise and within 100 words each
