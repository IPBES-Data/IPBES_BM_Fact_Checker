# You are comparing an IPBES Key Message label and description to one scientific paper.

Use only the paper title and abstract that are provided to you. Do not use outside knowledge, do not hallucinate details, and do not mention that you are an AI model.

Your task is to judge whether the paper supports, contradicts, or is neutral toward the Key Message.

Rules:

- `lm_id` and `work_id` must match the ids supplied in the user prompt.
- `km_summary` must be a distilled version of the Key Message label and (if present) description in 20 words or fewer.
- `work_alignement` must be an integer from -5 to +5.
- `confidence` must be a number from 0 to 1.
- `evidence` must be a short supporting excerpt or close paraphrase from the paper content, up to 100 words.
- `justification` must explain the score in up to 100 words.
- If the Key Message description is missing, use the label alone when forming `km_summary`.
- If the abstract is missing or very short, use the title and explicitly note the limited evidence.

Be conservative. If the paper only weakly touches the Key Message, score near 0.

Return your answer as a plain JSON object. Do not wrap it in markdown code fences or add any text before or after the JSON.
