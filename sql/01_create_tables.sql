-- 01_create_tables.sql
-- Builds analysis tables from the raw uploads: cleans dates and adds
-- BigQuery GEOGRAPHY columns for spatial queries.

-- Fire incident points
-- Dates were loaded as text because the source contains a few impossible
-- values (e.g. year 223). SAFE.PARSE_DATE returns NULL instead of failing,
-- and dates before 1900 are treated as missing.
CREATE OR REPLACE TABLE `bc-wildfire-bigquery.bc_wildfire.incidents` AS
SELECT
  * EXCEPT (IGNITION_DATE, FIRE_OUT_DATE),
  IF(SAFE.PARSE_DATE('%Y-%m-%d', IGNITION_DATE) >= DATE '1900-01-01',
     SAFE.PARSE_DATE('%Y-%m-%d', IGNITION_DATE), NULL) AS IGNITION_DATE,
  IF(SAFE.PARSE_DATE('%Y-%m-%d', FIRE_OUT_DATE) >= DATE '1900-01-01',
     SAFE.PARSE_DATE('%Y-%m-%d', FIRE_OUT_DATE), NULL) AS FIRE_OUT_DATE,
  ST_GEOGPOINT(LONGITUDE, LATITUDE) AS geog   -- NULL if coordinates missing
FROM `bc-wildfire-bigquery.bc_wildfire.fire_incidents_raw`;

-- Fire perimeters: parse WKT text into polygon geography.
-- make_valid repairs minor geometry problems; SAFE returns NULL instead of
-- failing the whole query if a shape cannot be parsed.
CREATE OR REPLACE TABLE `bc-wildfire-bigquery.bc_wildfire.perimeters` AS
SELECT
  * EXCEPT (geometry_wkt),
  SAFE.ST_GEOGFROMTEXT(geometry_wkt, make_valid => TRUE) AS geog
FROM `bc-wildfire-bigquery.bc_wildfire.fire_perimeters_raw`;


-- Check 1: row counts and missing geometries
SELECT 'incidents' AS tbl, COUNT(*) AS n_rows, COUNTIF(geog IS NULL) AS n_null_geog
FROM `bc-wildfire-bigquery.bc_wildfire.incidents`
UNION ALL
SELECT 'perimeters', COUNT(*), COUNTIF(geog IS NULL)
FROM `bc-wildfire-bigquery.bc_wildfire.perimeters`;


-- Check 2: what kinds of incidents are in the points data?
SELECT FIRE_TYPE, COUNT(*) AS n
FROM `bc-wildfire-bigquery.bc_wildfire.incidents`
GROUP BY FIRE_TYPE
ORDER BY n DESC;


-- Check 3: does the area calculated from the polygons match the recorded size?
-- ST_AREA returns square metres; divide by 10,000 for hectares.
SELECT
  FIRE_YEAR,
  FIRE_NUMBER,
  FIRE_SIZE_HECTARES,
  ROUND(ST_AREA(geog) / 10000, 1) AS calc_area_ha
FROM `bc-wildfire-bigquery.bc_wildfire.perimeters`
ORDER BY FIRE_SIZE_HECTARES DESC
LIMIT 10;


-- Check 4: ignition dates that were present in the source but invalid
SELECT
  r.FIRE_NUMBER,
  r.FIRE_YEAR,
  r.IGNITION_DATE AS raw_ignition_date
FROM `bc-wildfire-bigquery.bc_wildfire.fire_incidents_raw` AS r
WHERE r.IGNITION_DATE IS NOT NULL
  AND (SAFE.PARSE_DATE('%Y-%m-%d', r.IGNITION_DATE) IS NULL
       OR SAFE.PARSE_DATE('%Y-%m-%d', r.IGNITION_DATE) < DATE '1900-01-01');