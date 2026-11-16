-- Q0: Fire centre lookup, based on the BC Wildfire Service fire number prefix
CREATE OR REPLACE TABLE `bc-wildfire-bigquery.bc_wildfire.fire_centres` AS
SELECT * FROM UNNEST([
  STRUCT('C' AS prefix, 'Cariboo' AS fire_centre),
  ('G', 'Prince George'),
  ('K', 'Kamloops'),
  ('N', 'Southeast'),
  ('R', 'Northwest'),
  ('V', 'Coastal')
]);


-- Q0b: Validate the prefix lookup against the FIRE_CENTRE code in the data
SELECT
  LEFT(i.FIRE_NUMBER, 1) AS prefix,
  fc.fire_centre,
  i.FIRE_CENTRE AS centre_code,
  COUNT(*) AS n
FROM `bc-wildfire-bigquery.bc_wildfire.incidents` AS i
LEFT JOIN `bc-wildfire-bigquery.bc_wildfire.fire_centres` AS fc
  ON LEFT(i.FIRE_NUMBER, 1) = fc.prefix
WHERE i.FIRE_TYPE = 'Fire'
GROUP BY prefix, fc.fire_centre, centre_code
ORDER BY n DESC;


-- Q1: Annual number of fires (incident points) and area burned (perimeters)
-- Only true fires are counted (FIRE_TYPE = 'Fire'); perimeters supply area.
WITH counts AS (
  SELECT FIRE_YEAR, COUNT(*) AS n_fires
  FROM `bc-wildfire-bigquery.bc_wildfire.incidents`
  WHERE FIRE_TYPE = 'Fire'
  GROUP BY FIRE_YEAR
),
area AS (
  SELECT FIRE_YEAR,
         COUNT(*) AS n_perimeters,
         SUM(FIRE_SIZE_HECTARES) AS area_burned_ha
  FROM `bc-wildfire-bigquery.bc_wildfire.perimeters`
  GROUP BY FIRE_YEAR
)
SELECT
  FIRE_YEAR,
  n_fires,
  n_perimeters,
  ROUND(area_burned_ha) AS area_burned_ha
FROM counts
FULL OUTER JOIN area USING (FIRE_YEAR)
WHERE FIRE_YEAR >= 1950
ORDER BY FIRE_YEAR;


-- Q2: Fires and area burned by fire centre, 1950 onwards
WITH fires AS (
  SELECT LEFT(FIRE_NUMBER, 1) AS prefix, COUNT(*) AS n_fires
  FROM `bc-wildfire-bigquery.bc_wildfire.incidents`
  WHERE FIRE_TYPE = 'Fire' AND FIRE_YEAR >= 1950
  GROUP BY prefix
),
area AS (
  SELECT LEFT(FIRE_NUMBER, 1) AS prefix, SUM(FIRE_SIZE_HECTARES) AS area_ha
  FROM `bc-wildfire-bigquery.bc_wildfire.perimeters`
  WHERE FIRE_YEAR >= 1950
  GROUP BY prefix
)
SELECT
  fc.fire_centre,
  f.n_fires,
  ROUND(a.area_ha) AS area_burned_ha,
  ROUND(100 * a.area_ha / SUM(a.area_ha) OVER (), 1) AS pct_of_bc_area_burned
FROM `bc-wildfire-bigquery.bc_wildfire.fire_centres` AS fc
LEFT JOIN fires AS f USING (prefix)
LEFT JOIN area AS a USING (prefix)
ORDER BY area_burned_ha DESC;


-- Q3: Fires and area burned by cause, 1950 onwards
WITH fires AS (
  SELECT FIRE_CAUSE, COUNT(*) AS n_fires
  FROM `bc-wildfire-bigquery.bc_wildfire.incidents`
  WHERE FIRE_TYPE = 'Fire' AND FIRE_YEAR >= 1950
  GROUP BY FIRE_CAUSE
),
area AS (
  SELECT FIRE_CAUSE, SUM(FIRE_SIZE_HECTARES) AS area_ha
  FROM `bc-wildfire-bigquery.bc_wildfire.perimeters`
  WHERE FIRE_YEAR >= 1950
  GROUP BY FIRE_CAUSE
)
SELECT
  FIRE_CAUSE,
  n_fires,
  ROUND(100 * n_fires / SUM(n_fires) OVER (), 1) AS pct_of_fires,
  ROUND(area_ha) AS area_burned_ha,
  ROUND(100 * area_ha / SUM(area_ha) OVER (), 1) AS pct_of_area_burned
FROM fires
FULL OUTER JOIN area USING (FIRE_CAUSE)
ORDER BY area_burned_ha DESC;


-- Q4: Mean annual area burned and number of very large fires, by decade
-- Note: the 2020s cover 2020 to 2025 only (6 seasons).
SELECT
  DIV(FIRE_YEAR, 10) * 10 AS decade,
  COUNT(DISTINCT FIRE_YEAR) AS n_seasons,
  ROUND(SUM(FIRE_SIZE_HECTARES) / COUNT(DISTINCT FIRE_YEAR)) AS mean_annual_area_ha,
  COUNTIF(FIRE_SIZE_HECTARES >= 10000) AS n_fires_10000ha_plus
FROM `bc-wildfire-bigquery.bc_wildfire.perimeters`
WHERE FIRE_YEAR >= 1950
GROUP BY decade
ORDER BY decade;


-- Q5: Largest fires on record, with name, fire centre, cause, and ignition date
-- Joins perimeters to incident points on fire number and year.
SELECT
  p.FIRE_YEAR,
  p.FIRE_NUMBER,
  i.INCIDENT_NAME,
  fc.fire_centre,
  p.FIRE_CAUSE,
  i.IGNITION_DATE,
  ROUND(p.FIRE_SIZE_HECTARES) AS size_ha
FROM `bc-wildfire-bigquery.bc_wildfire.perimeters` AS p
LEFT JOIN `bc-wildfire-bigquery.bc_wildfire.fire_centres` AS fc
  ON LEFT(p.FIRE_NUMBER, 1) = fc.prefix
LEFT JOIN `bc-wildfire-bigquery.bc_wildfire.incidents` AS i
  ON i.FIRE_NUMBER = p.FIRE_NUMBER
 AND i.FIRE_YEAR = p.FIRE_YEAR
 AND i.FIRE_TYPE = 'Fire'
ORDER BY size_ha DESC
LIMIT 15;


-- Q6: Area burned within 50 km of selected BC communities, by decade
-- ST_DWITHIN finds perimeters within 50 km; ST_INTERSECTION clips each
-- perimeter to a 50 km buffer so only the nearby burned area is counted.
-- Note: areas that burned more than once are counted each time.
WITH communities AS (
  SELECT name, ST_GEOGPOINT(lon, lat) AS pt
  FROM UNNEST([
    STRUCT('Kamloops' AS name, -120.327 AS lon, 50.675 AS lat),
    ('Kelowna', -119.496, 49.888),
    ('Prince George', -122.749, 53.917),
    ('Williams Lake', -122.141, 52.141),
    ('Fort St. John', -120.846, 56.252)
  ])
)
SELECT
  c.name AS community,
  DIV(p.FIRE_YEAR, 10) * 10 AS decade,
  COUNT(*) AS n_fires_within_50km,
  ROUND(SUM(ST_AREA(ST_INTERSECTION(p.geog, ST_BUFFER(c.pt, 50000)))) / 10000)
    AS area_burned_within_50km_ha
FROM communities AS c
JOIN `bc-wildfire-bigquery.bc_wildfire.perimeters` AS p
  ON ST_DWITHIN(p.geog, c.pt, 50000)
WHERE p.FIRE_YEAR >= 1950
GROUP BY community, decade
ORDER BY community, decade;