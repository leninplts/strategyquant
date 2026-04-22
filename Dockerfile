FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive \
    SQX_HOME=/opt/sqx

# Dependencias mínimas. SQX trae su propio JVM en /j64,
# pero Java/Swing pide libs X aunque corras headless.
RUN apt-get update && apt-get install -y --no-install-recommends \
    unzip ca-certificates wget \
    libxrender1 libxtst6 libxi6 libxext6 libxrandr2 \
    libfreetype6 fontconfig fonts-dejavu \
    tini \
    && rm -rf /var/lib/apt/lists/*

WORKDIR ${SQX_HOME}

# URL del ZIP de SQX (se define en docker-compose.yml / env vars de Dokploy)
ARG SQX_ZIP_URL

RUN test -n "${SQX_ZIP_URL}" || (echo "ERROR: SQX_ZIP_URL no está definido" && exit 1) \
    && wget --no-verbose -O /tmp/sqx.zip "${SQX_ZIP_URL}" \
    && ls -lh /tmp/sqx.zip \
    && unzip -q /tmp/sqx.zip -d ${SQX_HOME} \
    && rm /tmp/sqx.zip \
    && find ${SQX_HOME} -maxdepth 3 -name "sqcli" -exec chmod +x {} \; \
    && find ${SQX_HOME} -maxdepth 3 -name "StrategyQuantX" -exec chmod +x {} \;

# Ajuste de heap de Java — tenés 64GB de RAM, podés darle holgado
ENV SQ_JVM_XMX=16g

EXPOSE 8090

# tini como PID 1 maneja señales correctamente para procesos Java
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["./sqcli", "-gui", "port=8090"]