library(dplyr)
library(readr)
library(googledrive)
library(epwshiftr)
library(eplusr)
library(data.table)
library(stringr)
library(jsonlite)

parse_args <- function(args) {
  result <- list(
    list_cities = FALSE,
    city = NULL,
    year = NULL,
    scenario = NULL,
    output_dir = NULL
  )

  i <- 1
  while (i <= length(args)) {
    arg <- args[[i]]
    if (!startsWith(arg, "--")) {
      stop(sprintf("Unexpected argument: %s", arg), call. = FALSE)
    }

    key <- substring(arg, 3)
    if (key == "list-cities") {
      result$list_cities <- TRUE
      i <- i + 1
      next
    }
    if (i == length(args)) {
      stop(sprintf("Missing value for --%s", key), call. = FALSE)
    }

    result[[key]] <- args[[i + 1]]
    i <- i + 2
  }

  result
}

usage <- function() {
  paste(
    "Usage:",
    "Rscript generate_future_weather.R --list-cities",
    "Rscript generate_future_weather.R --city \"Ahmedabad (GJ)\" --year 2050 --scenario ssp245 --output_dir output",
    sep = "\n"
  )
}

log_info <- function(...) {
  ts <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")
  message(sprintf("[%s] %s", ts, paste(..., collapse = " ")))
}

drive_deauth()
PUBLIC_EPW_FOLDER_ID <- "1ngc19Ln_H0kCvGx-oE2kkWXqTC8QEcwa"

get_public_epw_files <- function() {
  drive_ls(as_id(PUBLIC_EPW_FOLDER_ID), pattern = "\\.epw$") %>%
    mutate(
      filename = name,
      state = str_sub(name, 5, 6),
      city_part = str_extract(name, "(?<=IND_.._)[^.]+"),
      city_state = paste0(trimws(city_part), " (", state, ")")
    ) %>%
    arrange(city_state)
}

args <- parse_args(commandArgs(trailingOnly = TRUE))

log_info("Loading public EPW list...")
all_epw_files <- get_public_epw_files()

if (isTRUE(args$list_cities)) {
  cat(jsonlite::toJSON(all_epw_files$city_state, auto_unbox = TRUE, pretty = TRUE))
  quit(save = "no", status = 0)
}

required_args <- c("city", "year", "scenario", "output_dir")
missing_args <- required_args[vapply(required_args, function(x) is.null(args[[x]]), logical(1))]
if (length(missing_args) > 0) {
  stop(paste("Missing required arguments:", paste(missing_args, collapse = ", "), "\n", usage()), call. = FALSE)
}

yr <- as.integer(args$year)
scenario <- tolower(args$scenario)
city_name <- args$city
output_root <- normalizePath(args$output_dir, winslash = "/", mustWork = FALSE)

valid_scenarios <- c("ssp126", "ssp245", "ssp370", "ssp585")
if (is.na(yr) || yr %% 5 != 0 || yr < 2030 || yr > 2100) {
  stop("Year must be a multiple of 5 between 2030 and 2100.", call. = FALSE)
}
if (!scenario %in% valid_scenarios) {
  stop(sprintf("Scenario must be one of: %s", paste(valid_scenarios, collapse = ", ")), call. = FALSE)
}

dir.create(output_root, recursive = TRUE, showWarnings = FALSE)

sel <- all_epw_files %>% filter(city_state == city_name)
if (nrow(sel) == 0) {
  stop(sprintf("City not found: %s", city_name), call. = FALSE)
}
sel <- sel[1, ]

csv_url <- "https://docs.google.com/spreadsheets/d/1zqd_DA6BXeICJpL7tV6f5U5L_TuIVFk6M4dUiAD5tdI/export?format=csv"
log_info("Loading CMIP6 index...")
cmip6_index_all <- read_csv(csv_url, show_col_types = FALSE)

work_dir <- file.path(output_root, paste0("Future_", format(Sys.time(), "%Y%m%d_%H%M%S")))
dir.create(work_dir, recursive = TRUE, showWarnings = FALSE)

log_info("Selected city:", sel$city_state)
log_info("Year:", yr, "| Scenario:", toupper(scenario))

epw_path <- file.path(work_dir, sel$filename)
log_info("Downloading base EPW...")
drive_download(sel$id, path = epw_path, overwrite = TRUE)
log_info("Base EPW ready.")

years_needed <- c(yr - 1, yr, yr + 1)
year_strings <- sprintf("%d0101-%d1231", years_needed, years_needed)

log_info("Filtering CMIP6 records...")
filtered_data <- cmip6_index_all %>%
  mutate(
    year_tag = str_extract(file_url, "\\d{8}-\\d{8}"),
    file_name = basename(file_url)
  ) %>%
  filter(
    grepl(scenario, file_url, fixed = TRUE),
    year_tag %in% year_strings,
    variable_id %in% c(
      "tas", "tasmax", "tasmin", "hurs", "hursmax", "hursmin",
      "pr", "rsds", "rlds", "psl", "sfcWind", "clt"
    ),
    grepl("/fileServer/cmip6/", file_url)
  ) %>%
  group_by(variable_id, year_tag) %>%
  slice_head(n = 1) %>%
  ungroup() %>%
  mutate(
    file_id = paste0(dataset_id, "|", data_node),
    dataset_pid = pid
  ) %>%
  select(
    file_id, dataset_id, mip_era, activity_drs, institution_id, source_id,
    experiment_id, member_id, table_id, frequency, grid_label, version,
    nominal_resolution, variable_id, variable_long_name, variable_units,
    datetime_start, datetime_end, file_size, data_node, file_url,
    dataset_pid, tracking_id, file_name
  ) %>%
  distinct()

if (nrow(filtered_data) == 0) {
  stop("No CMIP6 files matched the selected year and scenario.", call. = FALSE)
}

log_info("Downloading", nrow(filtered_data), "NetCDF files...")
for (i in seq_len(nrow(filtered_data))) {
  dest <- file.path(work_dir, filtered_data$file_name[i])
  if (file.exists(dest)) {
    log_info(sprintf("[%d/%d] Already exists: %s", i, nrow(filtered_data), filtered_data$file_name[i]))
    next
  }

  log_info(sprintf("[%d/%d] Downloading: %s", i, nrow(filtered_data), filtered_data$file_name[i]))
  utils::download.file(filtered_data$file_url[i], dest, mode = "wb", quiet = TRUE, timeout = 1800)
}

idx_full <- filtered_data %>%
  mutate(
    file_realsize = file_size,
    file_mtime = Sys.time(),
    time_units = "days since 1850-01-01",
    time_calendar = "gregorian"
  )

idx_clean <- idx_full %>% select(-file_name)

log_info("Registering CMIP6 index...")
set_cmip6_index(as.data.table(idx_clean), save = FALSE)

options(epwshiftr.dir = work_dir)
summary_database(dir = work_dir, by = c("source", "variable"), mult = "latest")
log_info("NetCDF database registered.")

log_info("Reading EPW and matching coordinates...")
epw_obj <- read_epw(epw_path)
coord <- match_coord(epw_obj, threshold = list(lon = 6, lat = 6), max_num = 5)
if (length(coord) == 0) {
  log_info("No close match. Trying a larger search window...")
  coord <- match_coord(epw_obj, threshold = list(lon = 15, lat = 15), max_num = 5)
}
if (length(coord) == 0) {
  stop("No CMIP6 grid found for this city.", call. = FALSE)
}

log_info("Matched", length(coord), "grid cells. Extracting data...")
extracted <- extract_data(coord, years = yr)
morphed <- morphing_epw(extracted, years = yr, warn = FALSE)

log_info("Generating final future EPW files...")
future_epw(
  morphed,
  by = c("source", "experiment", "interval"),
  dir = work_dir,
  separate = TRUE,
  overwrite = TRUE,
  full = TRUE
)

future_files <- list.files(work_dir, pattern = "\\.epw$", full.names = TRUE)
future_files <- future_files[!grepl(basename(epw_path), future_files, fixed = TRUE)]
if (length(future_files) == 0) {
  stop("Future EPW generation completed but no output files were found.", call. = FALSE)
}

zipfile <- file.path(work_dir, "Future_Weather_Files.zip")
utils::zip(zipfile, future_files, flags = "-j")

manifest <- list(
  city = sel$city_state,
  year = yr,
  scenario = scenario,
  base_epw_name = basename(epw_path),
  future_files = basename(future_files),
  zip_name = basename(zipfile)
)

manifest_path <- file.path(work_dir, "result.json")
writeLines(jsonlite::toJSON(manifest, auto_unbox = TRUE, pretty = TRUE), manifest_path)

log_info("SUCCESS! Generated", length(future_files), "future EPW files.")
