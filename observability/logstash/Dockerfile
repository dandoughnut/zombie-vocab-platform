# Logstash plus the Postgres JDBC driver for the feedback pipeline. The jdbc
# input plugin ships with Logstash; the driver jar does not.
ARG ELASTIC_VERSION=9.5.5
FROM docker.elastic.co/logstash/logstash:${ELASTIC_VERSION}

ARG PGJDBC_VERSION=42.7.7
RUN mkdir -p /usr/share/logstash/drivers \
 && curl -fsSL -o /usr/share/logstash/drivers/postgresql.jar \
    "https://repo1.maven.org/maven2/org/postgresql/postgresql/${PGJDBC_VERSION}/postgresql-${PGJDBC_VERSION}.jar"

COPY --chown=logstash:root pipelines.yml /usr/share/logstash/config/pipelines.yml
COPY --chown=logstash:root pipeline/ /usr/share/logstash/pipeline/
COPY --chown=logstash:root sql/ /usr/share/logstash/sql/
