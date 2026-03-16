FROM python:3.10-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV PIP_NO_CACHE_DIR=1
ENV FUTURE_WEATHER_OUTPUT_DIR=/tmp/future-weather-runs
ENV PORT=7860

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    g++ \
    gcc \
    gfortran \
    git \
    libcurl4-openssl-dev \
    libfontconfig1-dev \
    libfribidi-dev \
    libharfbuzz-dev \
    libicu-dev \
    libnetcdf-dev \
    libpng-dev \
    libssl-dev \
    libxml2-dev \
    make \
    r-base \
    r-base-dev \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --upgrade pip && pip install -r requirements.txt

RUN Rscript -e "install.packages(c('dplyr','readr','googledrive','epwshiftr','eplusr','data.table','stringr','jsonlite'), repos='https://cloud.r-project.org')"

COPY . .

RUN mkdir -p /tmp/future-weather-runs

EXPOSE 7860

CMD ["sh", "-c", "streamlit run streamlit_app.py --server.address=0.0.0.0 --server.port=${PORT}"]
