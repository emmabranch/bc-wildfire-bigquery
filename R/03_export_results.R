# 03_export_results.R
# Runs the analysis queries in BigQuery once and saves the results to results/,
# so the website doesn't depend on the sandbox tables (which expire after 60 days).

library(bigrquery)
library(dplyr)
library(readr)
library(sf)

project <- "bc-wildfire-bigquery"
ds <- "`bc-wildfire-bigquery.bc_wildfire"

run_sql <- function(sql) bq_table_download(bq_project_query(project, sql))

dir.create("results", showWarnings = FALSE)

# ---- 1. Annual fires and area burned --------------------------------------
annual <- run_sql(paste0("
  WITH counts AS (
    SELECT FIRE_YEAR, COUNT(*) AS n_fires
    FROM ", ds, ".incidents`
    WHERE FIRE_TYPE = 'Fire'
    GROUP BY FIRE_YEAR
  ),
  area AS (
    SELECT FIRE_YEAR,
           SUM(FIRE_SIZE_HECTARES) AS area_burned_ha,
           COUNTIF(FIRE_SIZE_HECTARES >= 10000) AS n_large_fires
    FROM ", ds, ".perimeters`
    GROUP BY FIRE_YEAR
  )
  SELECT FIRE_YEAR AS fire_year, n_fires, area_burned_ha, n_large_fires
  FROM counts FULL OUTER JOIN area USING (FIRE_YEAR)
  WHERE FIRE_YEAR BETWEEN 1950 AND 2025
  ORDER BY fire_year
"))
write_csv(annual, "results/annual.csv")

# ---- 2. By fire centre and decade -----------------------------------------
centre_decade <- run_sql(paste0("
  WITH f AS (
    SELECT LEFT(FIRE_NUMBER, 1) AS prefix, DIV(FIRE_YEAR, 10) * 10 AS decade,
           COUNT(*) AS n_fires
    FROM ", ds, ".incidents`
    WHERE FIRE_TYPE = 'Fire' AND FIRE_YEAR BETWEEN 1950 AND 2025
    GROUP BY prefix, decade
  ),
  a AS (
    SELECT LEFT(FIRE_NUMBER, 1) AS prefix, DIV(FIRE_YEAR, 10) * 10 AS decade,
           SUM(FIRE_SIZE_HECTARES) AS area_ha
    FROM ", ds, ".perimeters`
    WHERE FIRE_YEAR BETWEEN 1950 AND 2025
    GROUP BY prefix, decade
  )
  SELECT fc.fire_centre, decade, n_fires, area_ha,
         -- 2020s cover 6 seasons (2020 to 2025); other decades cover 10
         area_ha / IF(decade = 2020, 6, 10) AS mean_annual_area_ha
  FROM f FULL OUTER JOIN a USING (prefix, decade)
  JOIN ", ds, ".fire_centres` AS fc USING (prefix)
  ORDER BY fire_centre, decade
"))
write_csv(centre_decade, "results/centre_decade.csv")

# ---- 3. By cause -----------------------------------------------------------
cause <- run_sql(paste0("
  WITH f AS (
    SELECT FIRE_CAUSE, COUNT(*) AS n_fires
    FROM ", ds, ".incidents`
    WHERE FIRE_TYPE = 'Fire' AND FIRE_YEAR BETWEEN 1950 AND 2025
    GROUP BY FIRE_CAUSE
  ),
  a AS (
    SELECT FIRE_CAUSE, SUM(FIRE_SIZE_HECTARES) AS area_ha
    FROM ", ds, ".perimeters`
    WHERE FIRE_YEAR BETWEEN 1950 AND 2025
    GROUP BY FIRE_CAUSE
  )
  SELECT FIRE_CAUSE AS cause, n_fires, area_ha,
         100 * n_fires / SUM(n_fires) OVER () AS pct_fires,
         100 * area_ha / SUM(area_ha) OVER () AS pct_area
  FROM f FULL OUTER JOIN a USING (FIRE_CAUSE)
  ORDER BY area_ha DESC
"))
write_csv(cause, "results/cause.csv")

# ---- 4. Area burned within 50 km of five communities ----------------------
communities <- run_sql(paste0("
  WITH communities AS (
    SELECT name, ST_GEOGPOINT(lon, lat) AS pt, lon, lat
    FROM UNNEST([
      STRUCT('Kamloops' AS name, -120.327 AS lon, 50.675 AS lat),
      ('Kelowna', -119.496, 49.888),
      ('Prince George', -122.749, 53.917),
      ('Williams Lake', -122.141, 52.141),
      ('Fort St. John', -120.846, 56.252)
    ])
  )
  SELECT
    c.name AS community, c.lon, c.lat,
    DIV(p.FIRE_YEAR, 10) * 10 AS decade,
    COUNT(*) AS n_fires_within_50km,
    SUM(ST_AREA(ST_INTERSECTION(p.geog, ST_BUFFER(c.pt, 50000)))) / 10000
      AS area_burned_within_50km_ha
  FROM communities AS c
  JOIN ", ds, ".perimeters` AS p
    ON ST_DWITHIN(p.geog, c.pt, 50000)
  WHERE p.FIRE_YEAR BETWEEN 1950 AND 2025
  GROUP BY community, c.lon, c.lat, decade
  ORDER BY community, decade
"))
write_csv(communities, "results/communities.csv")

# ---- 5. Large fires (10,000 ha or more) with simplified shapes for the map --
# BigQuery simplifies each shape to 250 m (ST_SIMPLIFY) and returns it as text,
# which keeps the web map fast. One row per fire.
large <- run_sql(paste0("
  SELECT
    p.FIRE_YEAR AS fire_year,
    p.FIRE_NUMBER AS fire_number,
    i.INCIDENT_NAME AS incident_name,
    fc.fire_centre,
    p.FIRE_CAUSE AS cause,
    i.IGNITION_DATE AS ignition_date,
    p.FIRE_SIZE_HECTARES AS size_ha,
    ST_ASTEXT(ST_SIMPLIFY(p.geog, 250)) AS wkt
  FROM ", ds, ".perimeters` AS p
  LEFT JOIN ", ds, ".fire_centres` AS fc
    ON LEFT(p.FIRE_NUMBER, 1) = fc.prefix
  LEFT JOIN ", ds, ".incidents` AS i
    ON i.FIRE_NUMBER = p.FIRE_NUMBER
   AND i.FIRE_YEAR = p.FIRE_YEAR
   AND i.FIRE_TYPE = 'Fire'
  WHERE p.FIRE_SIZE_HECTARES >= 10000
    AND p.FIRE_YEAR BETWEEN 1950 AND 2025
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY p.FIRE_NUMBER, p.FIRE_YEAR ORDER BY i.IGNITION_DATE
  ) = 1
  ORDER BY size_ha DESC
"))

large_sf <- large |>
  mutate(geometry = st_as_sfc(wkt, crs = 4326)) |>
  select(-wkt) |>
  st_as_sf()

st_write(large_sf, "results/large_fires.geojson", delete_dsn = TRUE, quiet = TRUE)

# ---- Checks ----------------------------------------------------------------
nrow(annual)          # expect 76
nrow(large_sf)        # expect about 256
file.size(list.files("results", full.names = TRUE)) / 1e6   # sizes in MB