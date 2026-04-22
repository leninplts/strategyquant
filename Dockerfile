FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive \
    SQX_HOME=/opt/sqx

# Dependencias mínimas. SQX trae su propio JVM en /j64,
# pero Java/Swing pide libs X aunque corras headless.
RUN apt-get update && apt-get install -y --no-install-recommends \
    unzip ca-certificates \
    libxrender1 libxtst6 libxi6 libxext6 libxrandr2 \
    libfreetype6 fontconfig fonts-dejavu \
    tini \
    && rm -rf /var/lib/apt/lists/*

WORKDIR ${SQX_HOME}

COPY vendor/SQX_143_linux_20260115.zip /tmp/sqx.zip
RUN unzip -q /tmp/sqx.zip -d ${SQX_HOME} \
    && rm /tmp/sqx.zip \
    && find ${SQX_HOME} -maxdepth 2 -name "sqcli" -exec chmod +x {} \; \
    && find ${SQX_HOME} -maxdepth 2 -name "StrategyQuantX" -exec chmod +x {} \;

# Ajuste de heap de Java — con 64GB de RAM del host,
# podés darle holgado a SQX. Cambiá si querés.
ENV SQ_JVM_XMX=16g

EXPOSE 8080

# tini como PID 1 maneja señales correctamente en Java
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["./sqcli", "-gui"]