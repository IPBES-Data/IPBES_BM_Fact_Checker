alignement_scoring_guide <- function() {
  paste(
    c(
      "-5 = strong contradiction",
      "-4 = clear contradiction",
      "-3 = moderate contradiction",
      "-2 = weak contradiction",
      "-1 = slight contradiction",
      "0 = neutral / not enough information",
      "+1 = slight support",
      "+2 = weak support",
      "+3 = moderate support",
      "+4 = clear support",
      "+5 = strong support"
    ),
    collapse = "\n"
  )
}

alignement_output_type <- function() {
  ellmer::type_object(
    .description = "Structured alignment assessment output for one KM and one OpenAlex work.",
    lm_id = ellmer::type_string("Key Message id used for the assessment"),
    work_id = ellmer::type_string("OpenAlex work id"),
    km_summary = ellmer::type_string(
      "Distilled summary of the Key Message label and description in 20 words or fewer"
    ),
    work_alignement = ellmer::type_integer(
      paste(
        "Alignment score from -5 to +5.",
        "Scoring guide:\n",
        alignement_scoring_guide()
      )
    ),
    confidence = ellmer::type_number("Confidence from 0 to 1"),
    evidence = ellmer::type_string(
      "Supporting evidence from title or abstract, 100 words max"
    ),
    justification = ellmer::type_string(
      "Short justification for the score, 100 words max"
    ),
    .required = TRUE,
    .additional_properties = FALSE
  )
}
