FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive \
    SQX_HOME=/opt/sqx \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    DISPLAY=:1 \
    VNC_PORT=5901 \
    NOVNC_PORT=8090 \
    VNC_RESOLUTION=1600x900 \
    VNC_COL_DEPTH=24

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates wget curl \
    libarchive-tools \
    # X11 libs que SQX necesita
    libxrender1 libxtst6 libxi6 libxext6 libxrandr2 \
    libfreetype6 fontconfig fonts-dejavu \
    # Display virtual + WM + VNC + noVNC
    xvfb fluxbox x11vnc novnc websockify \
    # Utilidades
    supervisor tini procps net-tools python3 \
    # dbus para machine-id (SQX lo lee para Hardware ID)
    dbus \
    # JRE de respaldo (la app trae su propio JRE en /opt/sqx/j64)
    openjdk-17-jre-headless \
    && rm -rf /var/lib/apt/lists/* \
    # Crear machine-id fijo: evita que SQX falle y estabiliza el Hardware ID
    # entre rebuilds (importante para la licencia).
    && mkdir -p /var/lib/dbus \
    && dbus-uuidgen > /etc/machine-id \
    && cp /etc/machine-id /var/lib/dbus/machine-id

WORKDIR ${SQX_HOME}

ARG SQX_ZIP_URL

RUN test -n "${SQX_ZIP_URL}" || (echo "ERROR: SQX_ZIP_URL no está definido" && exit 1) \
    && wget --no-verbose -O /tmp/sqx.zip "${SQX_ZIP_URL}" \
    && ls -lh /tmp/sqx.zip \
    && bsdtar -xf /tmp/sqx.zip -C ${SQX_HOME} \
    && rm /tmp/sqx.zip \
    && find ${SQX_HOME} -maxdepth 3 -name "sqcli" -exec chmod +x {} \; \
    && find ${SQX_HOME} -maxdepth 3 -name "StrategyQuantX" -exec chmod +x {} \; \
    && find ${SQX_HOME} -maxdepth 3 -name "*.sh" -exec chmod +x {} \;

ENV SQ_JVM_XMX=16g

# Entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Puerto noVNC (web) y VNC directo (por si quieres conectar con cliente nativo)
EXPOSE 8090 5901

ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
