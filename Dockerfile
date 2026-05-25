FROM rocker/r-ver:4.4.1

RUN apt-get update && apt-get install -y --no-install-recommends \
        libcurl4-openssl-dev \
        libssl-dev \
        libsodium-dev \
        libxml2-dev \
        libfontconfig1-dev \
    && rm -rf /var/lib/apt/lists/*

RUN R -e "install.packages(c('plumber','forecast','jsonlite','dplyr','tibble'), repos='https://cloud.r-project.org/')"

WORKDIR /app
COPY forecast.R plumber.R ./

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD R -e "httr::status_code(httr::GET('http://127.0.0.1:8080/'))" || exit 1

ENTRYPOINT ["R","-e","pr <- plumber::plumb('/app/plumber.R'); pr$run(host='0.0.0.0', port=8080)"]
