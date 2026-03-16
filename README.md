---
title: Future Weather Generator
emoji: "🌦️"
colorFrom: blue
colorTo: green
sdk: docker
app_port: 7860
fullWidth: true
---

# Future Weather Generator

This Space hosts a Streamlit UI with an R backend that generates future `.epw` weather files by morphing a baseline India EPW using CMIP6 climate projections.

## What it does

- Lets users choose a city, future year, and SSP scenario.
- Downloads the matching baseline EPW file from Google Drive.
- Downloads the required CMIP6 NetCDF files for the selected case.
- Uses `epwshiftr` to extract climate signals, morph the EPW, and generate future EPW outputs.
- Returns a ZIP file containing the generated future weather files.

## Deploy on Hugging Face Spaces

1. Create a new Space on Hugging Face.
2. Choose `Docker` as the SDK.
3. Push this repository to the Space.
4. Wait for the Docker build to finish.

The Space is configured through this README YAML block and the `Dockerfile`.

## Important runtime notes

- Free Hugging Face Spaces currently provide 2 vCPU, 16 GB RAM, and 50 GB ephemeral disk by default.
- The app downloads NetCDF files at runtime, so the first run can take a while.
- Free Spaces sleep when idle, and local files are not guaranteed to survive restarts.
- This is suitable for light public usage, not high traffic.

## Main files

- `streamlit_app.py`: web UI and download flow
- `generate_future_weather.R`: backend weather-generation pipeline
- `Dockerfile`: production container for Hugging Face Spaces

## Local run

```bash
pip install -r requirements.txt
streamlit run streamlit_app.py
```
