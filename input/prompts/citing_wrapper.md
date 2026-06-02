# Candidate paper

The following JSON object describes one scientific paper that has been linked to the reference document above through a snowball search (the paper cites a seed publication of the same KM/BM). Score how strongly this paper supports, contradicts, or is neutral toward the reference's position.

Schema:

- `assessment`, `km`, `bm` — id of the assessment and the KM/BM this paper was associated with via snowball. These must match the same fields in the reference document.
- `work_id` — OpenAlex work id. Use this exactly as `work_id` in your response.
- `doi`, `publication_year` — publication metadata, for context only.
- `relation` — relationship to the seed work (`"citing"` for now).
- `title` — paper title.
- `abstract` — paper abstract. May be missing, empty, or very short — note this in your `justification` and lower `confidence` accordingly.

Base your judgement on the title and abstract only. Do not invent or assume content that is not present in the JSON. If the abstract is empty, work from the title alone and explicitly say so.

Candidate paper JSON:
