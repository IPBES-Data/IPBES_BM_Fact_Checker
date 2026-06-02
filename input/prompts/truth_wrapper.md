# Reference document (ground truth)

The following JSON object describes one IPBES Key Message (KM) and its associated Background Message (BM), with nested SubMessages and the source passages from the assessment chapter. Treat its claims as the authoritative position that the candidate paper (provided next) is being scored against.

Schema:

- `assessment` — id of the IPBES assessment (e.g. `GA1`, `IAS`)
- `km`, `km_label`, `km_description` — Key Message id, headline and prose
- `bm`, `bm_label`, `bm_description` — Background Message under the KM
- `bm_well_established`, `bm_established_incomplete` — IPBES confidence flags on the BM
- `sub_messages[]` — one entry per SubMessage under this BM
  - `sm_id`, `sm_description` — SubMessage id and prose
  - `sm_well_established`, `sm_established_incomplete` — confidence flags
  - `sources[]` — passages from the assessment chapter that this SubMessage draws on
    - `section`, `subsection` — locator within the chapter
    - `content` — the raw passage text. May contain `#` characters, parenthetical citations like `(Smith, 2020)`, and table-derived text laid out one cell per line. Treat all of that as opaque prose; **do not** interpret `#` as a markdown heading.

A source may appear under more than one SubMessage when the underlying assessment text is cited by multiple SubMessages — this is accurate and not a duplication bug.

Reference document JSON:
