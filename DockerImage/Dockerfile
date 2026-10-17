# The TabEHR environment: the SparseArray stack plus what this package adds.
#
# Built on the same rocker/rstudio:4.1.2 base and the same pinned OHDSI
# versions as SparseArray/DockerImage/Dockerfile. PatientLevelPrediction is
# installed here as well, because SparseArray Imports it.
#
# arrow is deliberately not installed: every output of this package is CSV.
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
# the R 4.1.2 release, so these resolve to fixed versions.
RUN R -e "install.packages(c('devtools', 'dplyr', 'data.table', 'R.utils', 'rvg', 'jsonlite', 'Matrix', 'usethis', 'renv', 'lubridate', 'slam', 'checkmate', 'bit64', 'testthat'))"

# OHDSI packages, pinned to the same releases as SparseArray.
RUN R -e 'devtools::install_github("OHDSI/Andromeda", ref = "v0.6.0")'
RUN R -e 'devtools::install_github("OHDSI/SqlRender", ref = "v1.9.0")'
RUN R -e 'devtools::install_github("OHDSI/DatabaseConnector", ref = "v5.0.2")'
RUN R -e 'devtools::install_github("OHDSI/CohortGenerator", ref = "v0.4.0")'
RUN R -e 'devtools::install_github("OHDSI/ParallelLogger", ref = "v2.0.2")'
RUN R -e 'devtools::install_github("OHDSI/FeatureExtraction", ref = "v3.2.0")'
RUN R -e 'devtools::install_github("OHDSI/PatientLevelPrediction", ref = "v6.0.0")'

# JDBC driver for the study database.
RUN mkdir -p /home/rstudio/jdbc \
    && R -e "DatabaseConnector::downloadJdbcDrivers(dbms = 'sql server', pathToDriver = '/home/rstudio/jdbc')" \
    && chown -R rstudio:rstudio /home/rstudio/jdbc

# SparseArray is installed from the copy in this project, so the installed
# cohort SQL is the one with the @restrict_person_table parameter, and TabEHR
# on top of it.
COPY . /tmp/TabEHR
RUN R CMD INSTALL /tmp/TabEHR/SparseArray \
    && R CMD INSTALL /tmp/TabEHR \
    && rm -rf /tmp/TabEHR \
    && printf 'session-default-working-dir=/home/rstudio/tabehr\n' \
      > /etc/rstudio/rsession.conf

WORKDIR /home/rstudio/tabehr

CMD ["/init"]
