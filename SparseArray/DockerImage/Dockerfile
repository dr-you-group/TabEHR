# The R, Java, and OHDSI stack of the sibling SparseMatrix study package, so
# both projects run against the same tested environment:
# https://github.com/dr-you-group/SparseMatrix/blob/main/DockerImage/Dockerfile
#
# FeatureExtraction is pinned to v3.2.0, which is the version this package's
# temporal sequence covariates are built and tested against.
FROM rocker/rstudio:4.1.2

USER root

# Java development kit, required by rJava, DatabaseConnector, and the
# FeatureExtraction SQL generator.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      default-jdk \
      build-essential \
      libcurl4-gnutls-dev \
      libxml2-dev \
      libssl-dev \
      libgit2-dev \
      libfontconfig1-dev \
      libcairo2-dev \
      libsodium-dev \
    && rm -rf /var/lib/apt/lists/*
RUN R CMD javareconf
RUN R -e "install.packages('rJava', dependencies = TRUE)"

# CRAN dependencies. The base image pins the repository to a snapshot taken at
# the R 4.1.2 release, so these resolve to fixed versions. slam provides
# simple_sparse_array and checkmate the argument checks used by this package;
# both are additions to the SparseMatrix dependency set.
RUN R -e "install.packages(c('devtools', 'dplyr', 'data.table', 'R.utils', 'rvg', 'jsonlite', 'Matrix', 'usethis', 'renv', 'lubridate', 'slam', 'checkmate'))"

# OHDSI packages, pinned to the same releases as SparseMatrix.
RUN R -e 'devtools::install_github("OHDSI/Andromeda", ref = "v0.6.0")'
RUN R -e 'devtools::install_github("OHDSI/SqlRender", ref = "v1.9.0")'
RUN R -e 'devtools::install_github("OHDSI/DatabaseConnector", ref = "v5.0.2")'
RUN R -e 'devtools::install_github("OHDSI/CohortGenerator", ref = "v0.4.0")'
RUN R -e 'devtools::install_github("OHDSI/ParallelLogger", ref = "v2.0.2")'
RUN R -e 'devtools::install_github("OHDSI/FeatureExtraction", ref = "v3.2.0")'
# Imported by this package, so the R CMD INSTALL below needs it.
RUN R -e 'devtools::install_github("OHDSI/PatientLevelPrediction", ref = "v6.0.0")'

# JDBC driver for the study database. Compose points
# DATABASECONNECTOR_JAR_FOLDER here by default; set SPARSE_ARRAY_JDBC_FOLDER to
# a mounted folder to supply a site-specific driver instead.
RUN mkdir -p /home/rstudio/jdbc \
    && R -e "DatabaseConnector::downloadJdbcDrivers(dbms = 'sql server', pathToDriver = '/home/rstudio/jdbc')" \
    && chown -R rstudio:rstudio /home/rstudio/jdbc

COPY . /tmp/SparseArray
RUN R CMD INSTALL /tmp/SparseArray \
    && rm -rf /tmp/SparseArray \
    && printf 'session-default-working-dir=/home/rstudio/feature_extraction_v3\n' \
      > /etc/rstudio/rsession.conf

WORKDIR /home/rstudio/feature_extraction_v3

CMD ["/init"]
