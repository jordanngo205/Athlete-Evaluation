# =============================================================================
# render_prospect_cards.R
#
# Reads a combine CSV (schema below), computes each player's category
# percentiles from their letter grades (A=10% ... J=100%, averaged per
# category), and injects the result into prospect_card_template_white.html
# -- producing one populated HTML card per player.
#
# Usage:
#   Rscript render_prospect_cards.R
#   Rscript render_prospect_cards.R path/to/data.csv path/to/template.html out_dir
#
# Requires: readr, dplyr, purrr, jsonlite, stringr
#   install.packages(c("readr","dplyr","purrr","jsonlite","stringr"))
# =============================================================================

source('loadPackages.R')

args        <- commandArgs(trailingOnly = TRUE)
csv_path    <- if (length(args) >= 1) args[1] else "combine_dummy_data.csv"
template_path <- if (length(args) >= 2) args[2] else "prospect_card_template_white.html"
out_dir     <- if (length(args) >= 3) args[3] else "cards_out"

dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

# ---------------------------------------------------------------------------
# CSV_SCHEMA -- mirrors the JS CSV_SCHEMA in the HTML template exactly.
# Keep these two in sync if the CSV layout ever changes.
# ---------------------------------------------------------------------------
META_COLS <- c(
  name     = "name",
  age      = "age",
  position = "position",
  team     = "team",
  height   = "height",
  weight   = "weight",
  headshot = "headshot"
)

RAW_STAT_COLS <- c(
  "PPG"  = "ppg",
  "APG"  = "apg",
  "RPG"  = "rpg",
  "SPG"  = "spg",
  "BPG"  = "bpg",
  "FG%"  = "fg_pct",
  "3P%"  = "three_pct",
  "FT%"  = "ft_pct"
)

CATEGORIES <- list(
  scoring = list(
    label  = "Scoring",
    weight = 0.40,
    kpis   = c(
      "Off-the-dribble shooting" = "scoring_off_dribble",
      "Spot-Up Shooting"         = "scoring_spot_up",
      "Star Drill (3/Mid)"       = "scoring_star_drill",
      "Side-Mid-Side (3/Mid)"    = "scoring_side_mid_side",
      "Free Throw Shooting"      = "scoring_free_throw"
    )
  ),
  physical = list(
    label  = "Physical",
    weight = 0.125,
    kpis   = c(
      "Rel. Lower Body Strength" = "physical_rel_lower_body_strength",
      "Rate of Force Dev."       = "physical_rate_force_dev",
      "CMJ"                      = "physical_cmj",
      "Max Vertical Jump"        = "physical_max_vertical_jump",
      "Ecc. Rate of Force Dev."  = "physical_ecc_rate_force_dev",
      "Lateral Broad Jump"       = "physical_lateral_broad_jump",
      "3/4 Court Sprint"         = "physical_34_court_sprint",
      "10m Split"                = "physical_10m_split",
      "Lane Agility"             = "physical_lane_agility",
      "Reactive Agility Drill"   = "physical_reactive_agility_drill",
      "Yoyo"                     = "physical_yoyo"
    )
  ),
  anthro = list(
    label  = "Anthro",
    weight = 0.10,
    kpis   = c(
      "Height"         = "anthro_height",
      "Standing Reach" = "anthro_standing_reach",
      "Wingspan"       = "anthro_wingspan",
      "Hand Size"      = "anthro_hand_size",
      "Weight"         = "anthro_weight"
    )
  ),
  handle = list(
    label  = "Handle",
    weight = 0.125,
    kpis   = c(
      "All-Star Lane Agility"  = "handle_lane_agility",
      "Reactive Ball Handling" = "handle_reactive_ball_handling"
    )
  ),
  passing = list(
    label  = "Passing",
    weight = 0.125,
    kpis   = c(
      "PnR Passing"          = "passing_pnr",
      "Transition Passing"   = "passing_transition",
      "Scrimmage Scenarios"  = "passing_scrimmage"
    )
  ),
  defense = list(
    label  = "Defense",
    weight = 0.125,
    kpis   = c(
      "Containment Drill"        = "defense_containment",
      "Reactive Closeout Drill"  = "defense_reactive_closeout",
      "2v2 Ball Screen Nav."     = "defense_2v2_ball_screen",
      "Scrimmage Scenarios"      = "defense_scrimmage"
    )
  )
)

CAT_ORDER <- c("scoring", "physical", "anthro", "handle", "passing", "defense")

# A = 10% ... J = 100%
LETTER_TO_PERCENT <- setNames(seq(10, 100, by = 10), LETTERS[1:10])

# ---------------------------------------------------------------------------
# letter_to_pct(): vectorised letter -> percent, NA for blank/unrecognized
# ---------------------------------------------------------------------------
letter_to_pct <- function(letters_vec) {
  letters_vec <- toupper(trimws(letters_vec))
  unname(LETTER_TO_PERCENT[letters_vec])  # NA when not A-J or blank
}

# ---------------------------------------------------------------------------
# na_to_null(): jsonlite writes R's NA as `null` automatically when
# auto_unbox = TRUE and na = "null" is set on toJSON(); this helper is only
# needed for plain character NAs pulled from meta columns.
# ---------------------------------------------------------------------------
blank_to_na <- function(x) ifelse(is.na(x) | trimws(x) == "", NA, x)

# ---------------------------------------------------------------------------
# embed_headshot(): local image path -> base64 data URI, so each card stays a
# single self-contained file. data: URIs and http(s) URLs pass through
# untouched; a missing file warns and falls back to the placeholder glyph.
# Relative paths resolve against the CSV's own directory.
# ---------------------------------------------------------------------------
embed_headshot <- function(path) {
  if (is.na(path) || trimws(path) == "") return(NA_character_)
  path <- trimws(path)
  if (grepl("^(data:|https?://)", path)) return(path)

  resolved <- if (file.exists(path)) path else file.path(dirname(csv_path), path)
  if (!file.exists(resolved)) {
    warning("Headshot not found, using placeholder: ", path, call. = FALSE)
    return(NA_character_)
  }

  mime <- switch(
    tolower(tools::file_ext(resolved)),
    png  = "image/png",
    jpg  = "image/jpeg",
    jpeg = "image/jpeg",
    webp = "image/webp",
    gif  = "image/gif",
    NA_character_
  )
  if (is.na(mime)) {
    warning("Unsupported headshot type, using placeholder: ", path, call. = FALSE)
    return(NA_character_)
  }

  raw_img <- readBin(resolved, "raw", file.info(resolved)$size)
  b64     <- gsub("[\r\n]", "", base64_enc(raw_img))
  paste0("data:", mime, ";base64,", b64)
}

# ---------------------------------------------------------------------------
# build_player(): turns one CSV row into the same nested structure the
# JS buildPlayerFromRow() produces -- name/age/.../rawStats/categories.
# ---------------------------------------------------------------------------
build_player <- function(row) {
  
  meta <- setNames(
    lapply(META_COLS, function(col) {
      v <- if (col %in% names(row)) row[[col]] else NA
      unname(blank_to_na(v))
    }),
    names(META_COLS)
  )

  meta$headshot <- embed_headshot(meta$headshot)
  
  raw_stats <- setNames(
    lapply(RAW_STAT_COLS, function(col) {
      v <- if (col %in% names(row)) row[[col]] else NA
      unname(blank_to_na(v))
    }),
    names(RAW_STAT_COLS)
  )
  
  categories <- lapply(CAT_ORDER, function(key) {
    cat_def <- CATEGORIES[[key]]
    letters_used <- vapply(cat_def$kpis, function(col) {
      if (col %in% names(row)) row[[col]] else NA_character_
    }, character(1))
    
    pcts <- letter_to_pct(letters_used)
    kpis <- setNames(as.list(pcts), names(cat_def$kpis))
    
    cat_score <- if (all(is.na(pcts))) NA_real_ else round(mean(pcts, na.rm = TRUE), 1)
    
    list(
      label  = cat_def$label,
      weight = cat_def$weight,
      score  = cat_score,
      kpis   = kpis
    )
  })
  names(categories) <- CAT_ORDER
  
  c(meta, list(rawStats = raw_stats, categories = categories))
}

# ---------------------------------------------------------------------------
# slugify(): turns a player name into a safe filename
# ---------------------------------------------------------------------------
slugify <- function(x) {
  x <- if (is.na(x) || x == "") "player" else x
  x <- tolower(x)
  x <- str_replace_all(x, "[^a-z0-9]+", "_")
  str_replace_all(x, "^_+|_+$", "")
}

# ---------------------------------------------------------------------------
# inject_player(): writes one HTML card for a single player by replacing
# the template's preloaded-player JSON placeholder.
# ---------------------------------------------------------------------------
inject_player <- function(template_lines, player, out_path) {
  player_json <- toJSON(player, auto_unbox = TRUE, null = "null", na = "null")
  
  html <- paste(template_lines, collapse = "\n")
  html <- str_replace(
    html,
    fixed('<script id="preloaded-player" type="application/json">null</script>'),
    paste0(
      '<script id="preloaded-player" type="application/json">',
      player_json,
      '</script>'
    )
  )
  writeLines(html, out_path)
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main <- function() {
  message("Reading CSV: ", csv_path)
  # read every column as character so letter grades (A-J) and any
  # leading-zero-ish values are preserved exactly as typed
  df <- read_csv(csv_path, col_types = cols(.default = col_character()))
  
  template_lines <- readLines(template_path, warn = FALSE)
  
  players <- df %>% split(seq_len(nrow(.))) %>% map(build_player)
  
  walk2(players, seq_along(players), function(player, i) {
    slug <- slugify(player$name)
    out_path <- file.path(out_dir, paste0(slug, "_card.html"))
    inject_player(template_lines, player, out_path)
    
    overall_num <- NA_real_
    scores <- map_dbl(player$categories, function(c) if (is.null(c$score)) NA_real_ else c$score)
    weights <- map_dbl(player$categories, "weight")
    ok <- !is.na(scores)
    if (any(ok)) overall_num <- round(sum(scores[ok] * weights[ok]) / sum(weights[ok]), 1)
    
    message(sprintf("  [%d] %-20s overall: %s  -> %s",
                    i, player$name %||% "(unnamed)",
                    ifelse(is.na(overall_num), "--", overall_num),
                    out_path))
  })
  
  message("Done. ", length(players), " card(s) written to ", out_dir, "/")
}

`%||%` <- function(a, b) if (is.null(a) || is.na(a)) b else a

main()
