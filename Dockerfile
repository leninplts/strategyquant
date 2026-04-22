FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive \
    SQX_HOME=/opt/sqx \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates wget \
    libarchive-tools \
    libxrender1 libxtst6 libxi6 libxext6 libxrandr2 \
    libfreetype6 fontconfig fonts-dejavu \
    tini \
    && rm -rf /var/lib/apt/lists/*

WORKDIR ${SQX_HOME}

ARG SQX_ZIP_URL

RUN test -n "${SQX_ZIP_URL}" || (echo "ERROR: SQX_ZIP_URL no está definido" && exit 1) \
    && wget --no-verbose -O /tmp/sqx.zip "${SQX_ZIP_URL}" \
    && ls -lh /tmp/sqx.zip \
    && bsdtar -xf /tmp/sqx.zip -C ${SQX_HOME} \
    && rm /tmp/sqx.zip \
    && find ${SQX_HOME} -maxdepth 3 -name "sqcli" -exec chmod +x {} \; \
    && find ${SQX_HOME} -maxdepth 3 -name "StrategyQuantX" -exec chmod +x {} \;

ENV SQ_JVM_XMX=16g

# Entrypoint script: activa licencia si es necesario, luego levanta el webserver
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8090

ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]