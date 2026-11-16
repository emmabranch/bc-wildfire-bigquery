# 02_figures.R
# Queries the BigQuery tables directly from R (bigrquery) and makes figures.

library(bigrquery)
library(dplyr)
library(tidyr)
library(ggplot2)
library(scales)

project <- "bc-wildfire-bigquery"

# Helper: send SQL to BigQuery and download the result as a data frame
run_sql <- function(sql) {
  bq_table_download(bq_project_query(project, sql))
}

# ---- Figure 1: annual fires and area burned, 1950 to 2025 -----------------
annual <- run_sql("
  WITH counts AS (
    SELECT FIRE_YEAR, COUNT(*) AS n_fires
    FROM `bc-wildfire-bigquery.bc_wildfire.incidents`
    WHERE FIRE_TYPE = 'Fire'
    GROUP BY FIRE_YEAR
  ),
  area AS (
    SELECT FIRE_YEAR, SUM(FIRE_SIZE_HECTARES) AS area_burned_ha
    FROM `bc-wildfire-bigquery.bc_wildfire.perimeters`
    GROUP BY FIRE_YEAR
  )
  SELECT FIRE_YEAR, n_fires, area_burned_ha
  FROM counts FULL OUTER JOIN area USING (FIRE_YEAR)
  WHERE FIRE_YEAR BETWEEN 1950 AND 2025
  ORDER BY FIRE_YEAR
")

annual_long <- annual |>
  mutate(area_burned_kha = area_burned_ha / 1000) |>
  select(FIRE_YEAR, n_fires, area_burned_kha) |>
  pivot_longer(-FIRE_YEAR, names_to = "metric", values_to = "value") |>
  mutate(metric = recode(metric,
                         n_fires = "Number of fires",
                         area_burned_kha = "Area burned (thousand hectares)"
  ))

fig1 <- ggplot(annual_long, aes(FIRE_YEAR, value)) +
  geom_col(fill = "#C1440E", width = 0.8) +
  facet_wrap(~ metric, ncol = 1, scales = "free_y") +
  scale_y_continuous(labels = label_comma()) +
  labs(
    title = "BC wildfires, 1950 to 2025: fewer fires, far more area burned",
    subtitle = "Fire counts from incident points (true fires only); area from mapped perimeters",
    x = NULL, y = NULL,
    caption = "Data: BC Wildfire Service via BC Data Catalogue. Analysis in Google BigQuery."
  ) +
  theme_minimal(base_size = 12) +
  theme(strip.text = element_text(face = "bold", hjust = 0),
        panel.grid.minor = element_blank())

ggsave("figures/fig1_annual_fires_area.png", fig1, width = 9, height = 6, dpi = 300)

# ---- Figure 2: mean annual area burned by fire centre and decade ----------
by_centre <- run_sql("
  WITH p AS (
    SELECT
      fc.fire_centre,
      DIV(FIRE_YEAR, 10) * 10 AS decade,
      FIRE_SIZE_HECTARES
    FROM `bc-wildfire-bigquery.bc_wildfire.perimeters` AS per
    JOIN `bc-wildfire-bigquery.bc_wildfire.fire_centres` AS fc
      ON LEFT(per.FIRE_NUMBER, 1) = fc.prefix
    WHERE FIRE_YEAR BETWEEN 1950 AND 2025
  )
  SELECT
    fire_centre,
    decade,
    -- 2020s cover 6 seasons (2020 to 2025); other decades cover 10
    SUM(FIRE_SIZE_HECTARES) / IF(decade = 2020, 6, 10) AS mean_annual_area_ha
  FROM p
  GROUP BY fire_centre, decade
  ORDER BY fire_centre, decade
")

fig2 <- ggplot(by_centre, aes(factor(decade), mean_annual_area_ha / 1000)) +
  geom_col(fill = "#C1440E", width = 0.75) +
  facet_wrap(~ fire_centre, ncol = 3) +
  scale_y_continuous(labels = label_comma()) +
  labs(
    title = "Mean annual area burned by fire centre and decade",
    subtitle = "2020s = 2020 to 2025 seasons",
    x = "Decade", y = "Thousand hectares per year",
    caption = "Data: BC Wildfire Service via BC Data Catalogue. Analysis in Google BigQuery."
  ) +
  theme_minimal(base_size = 12) +
  theme(strip.text = element_text(face = "bold", hjust = 0),
        panel.grid.minor = element_blank(),
        panel.grid.major.x = element_blank(),
        axis.text.x = element_text(angle = 45, hjust = 1))

ggsave("figures/fig2_area_by_centre_decade.png", fig2, width = 10, height = 6, dpi = 300)