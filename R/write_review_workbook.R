# Reviewer workbooks (.xlsx) for the gold standard. Ported from
# ../technology_paper/R/write_review_workbook.R (itself from SEAMPHONI) and
# adapted to this instrument's columns. Built so that wrong entries are hard to
# make:
# - Review sheet: only `verdict` (a dropdown of GOLDSTANDARD_VERDICTS) and
#   `note` are editable. An empty verdict stays highlighted until it is filled,
#   and so does an empty note on a CANNOT_JUDGE row (the guide requires one).
#   Protected without a password, so id, claim, title and abstract cannot be
#   changed and rows cannot be sorted -- the two reviewers' files are matched on
#   id and their row orders differ on purpose.
# - Instructions sheet (the one it opens on): steps, label meanings, an invented
#   example row, the reviewer's initials and a progress counter. Locked except
#   the initials cell.
# - Guide sheet: REVIEWER_GUIDE.md, converted, locked.
# - Lists sheet: the dropdown's options, very hidden and protected.
# Nothing from the models (labels, confidence, strata, set meaning) is shown.

goldstandard_label_meanings <- function() c(
  SUPPORTS = "The abstract reports a finding that makes the claim more likely to be true.",
  REFUTES = "The abstract reports a finding that makes the claim less likely to be true -- also when it holds only for part of the claim's scope (say which part in note).",
  NOT_ENOUGH_INFO = "You read the abstract and it does not settle the claim either way. A real judgement, not a fallback.",
  CANNOT_JUDGE = "Something is wrong with the row (abstract not in English, truncated, not an abstract; claim too fragmentary). Say which in note."
)

# `tpl`: id, claim, title, abstract -- in the row order the reviewer gets.
# Deliberately no doi or any other column: the reviewer sees exactly what the
# model sees (claim + title + abstract), so a DOI link to the full paper would
# measure a different judgement from the one being benchmarked.
write_review_workbook <- function(tpl, file, guide_file = "input/goldstandard/REVIEWER_GUIDE.md") {
  stopifnot(all(c("id", "claim", "title", "abstract") %in% names(tpl)))
  labels <- goldstandard_label_meanings()
  stopifnot(identical(names(labels), GOLDSTANDARD_VERDICTS))
  n <- nrow(tpl)
  rows <- seq_len(n) + 1
  # A..D locked text, E verdict, F note
  wb <- openxlsx::createWorkbook()
  openxlsx::modifyBaseFont(wb, fontName = "Arial", fontSize = 10)
  head_style <- openxlsx::createStyle(textDecoration = "bold", fgFill = "#D9E2EA", wrapText = TRUE, valign = "center", border = "bottom")
  text_style <- openxlsx::createStyle(wrapText = TRUE, valign = "top", locked = TRUE)
  input_style <- openxlsx::createStyle(fgFill = "#FFF6D5", valign = "top", wrapText = TRUE, locked = FALSE, border = "TopBottomLeftRight", borderColour = "#C9CED3")
  empty_style <- openxlsx::createStyle(fgFill = "#F8CBAD")
  unprotect_view <- function(sheet) openxlsx::protectWorksheet(
    wb, sheet, protect = TRUE, lockFormattingColumns = FALSE, lockFormattingRows = FALSE,
    lockSelectingLockedCells = FALSE, lockSelectingUnlockedCells = FALSE)

  # sheets in display order, so the workbook opens on Instructions
  openxlsx::addWorksheet(wb, "Instructions")
  openxlsx::addWorksheet(wb, "Guide")
  openxlsx::addWorksheet(wb, "Review")
  write_guide_sheet(wb, "Guide", guide_file)
  openxlsx::addWorksheet(wb, "Lists", visible = "veryHidden")
  openxlsx::writeData(wb, "Lists", data.frame(verdict = GOLDSTANDARD_VERDICTS))
  openxlsx::protectWorksheet(wb, "Lists", protect = TRUE)

  # ── Review ──────────────────────────────────────────────────────────────
  review <- data.frame(id = tpl$id, claim = tpl$claim, title = tpl$title,
                       abstract = tpl$abstract,
                       verdict = NA_character_, note = NA_character_)
  openxlsx::writeData(wb, "Review", review, headerStyle = head_style)
  openxlsx::addStyle(wb, "Review", text_style, rows = rows, cols = 1:4, gridExpand = TRUE)
  openxlsx::addStyle(wb, "Review", input_style, rows = rows, cols = 5:6, gridExpand = TRUE)
  openxlsx::dataValidation(wb, "Review", cols = 5, rows = rows, type = "list",
                           value = sprintf("'Lists'!$A$2:$A$%d", length(GOLDSTANDARD_VERDICTS) + 1))
  openxlsx::conditionalFormatting(wb, "Review", cols = 5, rows = rows, rule = "LEN($E2)=0", style = empty_style)
  openxlsx::conditionalFormatting(wb, "Review", cols = 6, rows = rows,
                                  rule = 'AND($E2="CANNOT_JUDGE",LEN($F2)=0)', style = empty_style)
  openxlsx::setColWidths(wb, "Review", cols = 1:6, widths = c(13, 50, 34, 80, 20, 40))
  openxlsx::setRowHeights(wb, "Review", rows = 1, heights = 24)
  # tall enough for most abstracts; longer ones are read in the formula bar
  len <- pmax(nchar(ifelse(is.na(tpl$abstract), "", tpl$abstract)) / 105,
              nchar(ifelse(is.na(tpl$claim), "", tpl$claim)) / 65)
  openxlsx::setRowHeights(wb, "Review", rows = rows, heights = pmin(409, pmax(45, ceiling(len) * 13 + 8)))
  openxlsx::freezePane(wb, "Review", firstActiveRow = 2, firstActiveCol = 3)
  unprotect_view("Review")

  # ── Instructions ────────────────────────────────────────────────────────
  ins <- "Instructions"
  bold <- openxlsx::createStyle(textDecoration = "bold")
  openxlsx::writeData(wb, ins, "IPBES claim/paper verdicts: review workbook", startRow = 1)
  openxlsx::addStyle(wb, ins, openxlsx::createStyle(fontSize = 14, textDecoration = "bold"), rows = 1, cols = 1)
  steps <- c(
    "Read the Guide sheet (the same text as REVIEWER_GUIDE.md) once before you start. It defines the verdicts and the rules for borderline cases.",
    "On the Review sheet, choose a verdict for each row from the dropdown. Empty verdicts stay highlighted until they are filled.",
    "note: free text, always worth a line when you hesitated; required for CANNOT_JUDGE (it stays highlighted until you write one).",
    "Long claims and abstracts may not fit in the cell: click the cell and read it in the formula bar.",
    "Work on your own and don't discuss rows with the other reviewer until both workbooks are finished.",
    sprintf("Save as %s (drop _template), keep it as .xlsx, and send it back.", sub("_template", "", basename(file)))
  )
  openxlsx::writeData(wb, ins, data.frame(`How to fill in` = paste0(seq_along(steps), ". ", steps), check.names = FALSE), startRow = 3, headerStyle = bold)

  openxlsx::writeData(wb, ins, "Your initials:", startRow = 11)
  openxlsx::addStyle(wb, ins, bold, rows = 11, cols = 1)
  openxlsx::addStyle(wb, ins, input_style, rows = 11, cols = 2)
  openxlsx::writeData(wb, ins, "Rows with a verdict:", startRow = 12)
  openxlsx::addStyle(wb, ins, bold, rows = 12, cols = 1)
  openxlsx::writeFormula(wb, ins, sprintf('COUNTA(Review!E2:E%d)&" of %d"', n + 1, n), startCol = 2, startRow = 12)

  openxlsx::writeData(wb, ins, data.frame(verdict = names(labels), meaning = unname(labels)),
                      startRow = 14, headerStyle = bold)
  ex_row <- 14 + length(labels) + 2
  openxlsx::writeData(wb, ins, "Example (invented, not one of your rows)", startRow = ex_row)
  openxlsx::addStyle(wb, ins, bold, rows = ex_row, cols = 1)
  openxlsx::writeData(wb, ins, data.frame(
    claim = "Inland wetland area has declined worldwide since 1970.",
    title = "Inland wetland extent increased in two Scottish catchments, 1990-2015",
    verdict = "REFUTES",
    note = "only two catchments, but the direction runs against the claim for part of its scope"
  ), startRow = ex_row + 1, headerStyle = bold)

  openxlsx::addStyle(wb, ins, openxlsx::createStyle(wrapText = TRUE, valign = "top"), rows = 4:(ex_row + 2), cols = 1:4, gridExpand = TRUE, stack = TRUE)
  openxlsx::setColWidths(wb, ins, cols = 1:4, widths = c(60, 80, 18, 40))
  unprotect_view(ins)
  openxlsx::activeSheet(wb) <- 1

  openxlsx::saveWorkbook(wb, file, overwrite = TRUE)
  invisible(file)
}

# The reviewer guide (Markdown) as a locked, readable sheet. Works on BLOCKS
# (blank-line separated), not lines: the guide is hard-wrapped at ~80 chars, and
# a row per source line broke every paragraph into fragments. Column A is a
# narrow gutter (bullets), B holds the text; no merged cells, since Excel never
# sizes merged rows. Row heights are estimated, so they err on the tall side.
#   # / ##          title / section heading
#   **Lead.** rest  the bold lead-in becomes a bold sub-heading row, rest below
#   - item          a bullet row
#   > quote         shaded italic rows
#   | table |       one bullet row per body row: "col1 — col2"
guide_blocks <- function(lines) {
  lines <- sub("\\s+$", "", lines)
  grp <- cumsum(!nzchar(lines))
  blocks <- split(lines[nzchar(lines)], grp[nzchar(lines)])
  out <- list()
  add <- function(type, text) out[[length(out) + 1]] <<- list(type = type, text = text)
  clean <- function(x) trimws(gsub("\\*\\*|`|\\*", "", x))
  for (b in blocks) {
    quote <- all(startsWith(b, ">"))
    if (quote) b <- sub("^>\\s?", "", b)
    if (startsWith(b[1], "#")) {
      add(if (startsWith(b[1], "# ")) "h1" else "h2", clean(sub("^#+\\s*", "", b[1])))
    } else if (startsWith(b[1], "|")) {
      body <- b[-1][!grepl("^\\|[- |:]+\\|$", b[-1])]
      for (l in body) {
        cells <- clean(strsplit(sub("^\\|", "", sub("\\|$", "", l)), "|", fixed = TRUE)[[1]])
        add("bullet", paste(cells, collapse = " — "))
      }
    } else if (grepl("^- ", b[1])) {
      items <- split(b, cumsum(grepl("^- ", b)))
      for (it in items) add("bullet", clean(paste(sub("^- ", "", trimws(it)), collapse = " ")))
    } else {
      # quotes may hold several paragraphs, split on bare ">" lines
      paras <- if (quote) split(b[nzchar(b)], cumsum(!nzchar(b))[nzchar(b)]) else list(b)
      for (p in paras) {
        text <- paste(trimws(p), collapse = " ")
        lead <- regmatches(text, regexec("^\\*\\*(.+?)\\*\\*\\s*[—:-]?\\s*(.*)$", text, perl = TRUE))[[1]]
        if (!quote && length(lead) == 3 && nzchar(lead[3])) {
          add("h3", clean(lead[2]))
          text <- paste0(toupper(substr(lead[3], 1, 1)), substring(lead[3], 2))
        }
        add(if (quote) "quote" else "para", clean(text))
      }
    }
    add("gap", "")
  }
  out
}

write_guide_sheet <- function(wb, sheet, guide_file) {
  blocks <- guide_blocks(readLines(guide_file, encoding = "UTF-8", warn = FALSE))
  openxlsx::showGridLines(wb, sheet, showGridLines = FALSE)
  styles <- list(
    h1 = openxlsx::createStyle(fontSize = 16, textDecoration = "bold", fontColour = "#1F3A5F", valign = "bottom"),
    h2 = openxlsx::createStyle(fontSize = 12, textDecoration = "bold", fontColour = "#1F3A5F", valign = "bottom", border = "bottom", borderColour = "#9FB3C8"),
    h3 = openxlsx::createStyle(textDecoration = "bold", valign = "bottom"),
    para = openxlsx::createStyle(wrapText = TRUE, valign = "top"),
    bullet = openxlsx::createStyle(wrapText = TRUE, valign = "top"),
    quote = openxlsx::createStyle(wrapText = TRUE, valign = "top", textDecoration = "italic", fgFill = "#F2F4F7")
  )
  chars_per_line <- 105   # column B width 100 at Arial 10, minus some slack
  row <- 1
  for (b in blocks) {
    if (b$type == "gap") {
      openxlsx::setRowHeights(wb, sheet, rows = row, heights = 8)
    } else {
      openxlsx::writeData(wb, sheet, b$text, startCol = 2, startRow = row)
      openxlsx::addStyle(wb, sheet, styles[[b$type]], rows = row, cols = 2)
      if (b$type == "bullet") openxlsx::writeData(wb, sheet, "•", startCol = 1, startRow = row)
      if (b$type == "quote") openxlsx::addStyle(wb, sheet, styles$quote, rows = row, cols = 1)
      if (b$type == "h2") openxlsx::addStyle(wb, sheet, styles$h2, rows = row, cols = 1)
      lines <- max(1, ceiling(nchar(b$text) / chars_per_line))
      openxlsx::setRowHeights(wb, sheet, rows = row, heights = switch(
        b$type, h1 = 28, h2 = 26, h3 = 18, lines * 13 + 5))
    }
    row <- row + 1
  }
  openxlsx::addStyle(wb, sheet, openxlsx::createStyle(halign = "right", valign = "top"),
                     rows = seq_len(row), cols = 1, gridExpand = TRUE, stack = TRUE)
  openxlsx::setColWidths(wb, sheet, cols = 1:2, widths = c(3, 100))
  openxlsx::protectWorksheet(wb, sheet, protect = TRUE,
                             lockFormattingColumns = FALSE, lockFormattingRows = FALSE,
                             lockSelectingLockedCells = FALSE, lockSelectingUnlockedCells = FALSE)
}

# Writes Rx_<id>_<set>_template.xlsx next to every Rx_<id>_<set>_template.csv,
# same rows in the same order -- for a round that was drawn before the workbooks
# existed, so it gets them without being redrawn. Refuses to replace existing
# workbooks unless force = TRUE; filled workbooks are never touched.
build_review_workbooks <- function(output_dir = "input/goldstandard", force = FALSE) {
  csv <- list.files(output_dir, "^R[0-9]+_.+_template\\.csv$", full.names = TRUE)
  xlsx <- sub("\\.csv$", ".xlsx", csv)
  if (any(file.exists(xlsx)) && !force) {
    stop("Workbooks exist in ", output_dir, "; use force = TRUE only to replace them.", call. = FALSE)
  }
  for (i in seq_along(csv)) {
    write_review_workbook(utils::read.csv(csv[i], stringsAsFactors = FALSE, na.strings = ""),
                          xlsx[i], file.path(output_dir, "REVIEWER_GUIDE.md"))
  }
  invisible(xlsx)
}
