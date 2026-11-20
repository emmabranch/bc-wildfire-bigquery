# 04_banner.R
# Makes the home page banner: one stripe per fire season (1950 to 2025),
# coloured by area burned (log scale). Dark = small seasons, bright = large.

library(readr)
library(ggplot2)

annual <- read_csv("results/annual.csv", show_col_types = FALSE)
dir.create("figures", showWarnings = FALSE)

banner <- ggplot(annual, aes(x = fire_year, y = 1, fill = log10(area_burned_ha))) +
  geom_tile(width = 1) +
  scale_fill_gradientn(
    colours = c("#2b1d16", "#6b1f0f", "#b33a0e", "#e8681a", "#ffb347", "#ffe8a3"),
    guide = "none"
  ) +
  scale_x_continuous(expand = c(0, 0)) +
  scale_y_continuous(expand = c(0, 0)) +
  theme_void()

ggsave("figures/banner_stripes.png", banner, width = 16, height = 6, dpi = 150)
