# 01_download_data.R
# Downloads BC Wildfire Service historical fire data from the BC Data Catalogue
# one fire year at a time (the full layers are too large for one request),
# then writes BigQuery-ready CSV files to data/.

library(bcdata)
library(sf)
library(dplyr)
library(readr)

# Helper: convert date fields to plain YYYY-MM-DD so BigQuery reads them cleanly
fix_dates <- function(df, cols) {
  mutate(df, across(any_of(cols), ~ as.Date(substr(as.character(.x), 1, 10))))
}

# Helper: download one fire year, retrying up to 3 times if the server fails
get_year <- function(record_id, yr, tries = 3) {
  for (i in seq_len(tries)) {
    out <- tryCatch(
      bcdc_query_geodata(record_id) |>
        filter(FIRE_YEAR == local(yr)) |>
        collect(),
      error = function(e) NULL
    )
    if (!is.null(out)) return(out)
    message("  Retry ", i, " for year ", yr)
    Sys.sleep(5)
  }
  warning("Failed to download year ", yr)
  NULL
}

# Helper: make column types match across years before combining.
# Some fields (e.g. VERSION_NUMBER) are text in some years and numeric in
# others; any column with mixed types is converted to text.
# Geometry columns are left alone.
harmonise_types <- function(pieces) {
  cols <- unique(unlist(lapply(pieces, names)))
  for (col in cols) {
    if (any(sapply(pieces, function(d) inherits(d[[col]], "sfc")))) next
    classes <- unique(unlist(lapply(pieces, function(d) {
      if (col %in% names(d)) class(d[[col]])[1]
    })))
    if (length(classes) > 1) {
      message("Converting ", col, " to text (types differ: ",
              paste(classes, collapse = ", "), ")")
      pieces <- lapply(pieces, function(d) {
        if (col %in% names(d)) {
          x <- d[[col]]
          if (is.double(x)) {
            x <- ifelse(is.na(x), NA, format(x, scientific = FALSE, trim = TRUE))
          }
          d[[col]] <- as.character(x)
        }
        d
      })
    }
  }
  pieces
}

# Helper: loop over years, save the raw pieces, harmonise types, and combine
get_all_years <- function(record_id, years, checkpoint) {
  pieces <- lapply(years, function(yr) {
    message("Year ", yr)
    get_year(record_id, yr)
  })
  pieces <- Filter(Negate(is.null), pieces)
  saveRDS(pieces, checkpoint)    # save before combining, so nothing is lost
  bind_rows(harmonise_types(pieces))
}

# ---- 1. Fire incident points ---------------------------------------------
# Record: BC Wildfire Fire Incident Locations - Historical
incidents <- get_all_years("e2dadc60-292f-4d98-b42b-56ca9e4fe694", 1950:2025,
                           "data/incidents_pieces.rds")
names(incidents)
nrow(incidents)
table(incidents$FIRE_YEAR) |> range()   # sanity check on counts per year
saveRDS(incidents, "data/incidents_raw.rds")   # so you never re-download

incidents_out <- incidents |>
  st_drop_geometry() |>          # we keep LATITUDE/LONGITUDE instead
  select(any_of(c("FIRE_NUMBER", "FIRE_YEAR", "FIRE_TYPE", "FIRE_CAUSE",
                  "FIRE_CENTRE", "ZONE", "RESPONSE_TYPE_DESC",
                  "IGNITION_DATE", "FIRE_OUT_DATE", "CURRENT_SIZE",
                  "LATITUDE", "LONGITUDE", "INCIDENT_NAME"))) |>
  fix_dates(c("IGNITION_DATE", "FIRE_OUT_DATE"))

write_csv(incidents_out, "data/fire_incidents.csv", na = "")

# ---- 2. Fire perimeters (polygons) ---------------------------------------
# Record: BC Wildfire Fire Perimeters - Historical
perims <- get_all_years("22c7cb44-1463-48f7-8e47-88857f207702", 1917:2025,
                        "data/perimeters_pieces.rds")
names(perims)
nrow(perims)
saveRDS(perims, "data/perimeters_raw.rds")

perims_simple <- perims |>
  st_make_valid() |>
  # Simplify to a 50 m tolerance (data are in BC Albers, metres) to keep the
  # file small enough to upload; fine for provincial-scale summaries
  st_simplify(dTolerance = 50, preserveTopology = TRUE) |>
  st_transform(4326)               # BigQuery GEOGRAPHY needs WGS84 lon/lat

perims_out <- perims_simple |>
  mutate(geometry_wkt = st_as_text(st_geometry(perims_simple))) |>
  st_drop_geometry() |>
  select(-any_of(c("SE_ANNO_CAD_DATA", "OBJECTID", "FEATURE_AREA_SQM",
                   "FEATURE_LENGTH_M"))) |>
  fix_dates(c("FIRE_DATE", "LOAD_DATE"))

write_csv(perims_out, "data/fire_perimeters.csv", na = "")

# ---- 3. Check file sizes (console upload limit is 100 MB per file) -------
file.size(c("data/fire_incidents.csv", "data/fire_perimeters.csv")) / 1e6