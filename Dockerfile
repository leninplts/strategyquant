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

# Paquetes base + X11 + Xvfb/VNC/noVNC + dependencias de Electron
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates wget curl libarchive-tools tini procps net-tools python3 netcat-openbsd \
    # X11
    libxrender1 libxtst6 libxi6 libxext6 libxrandr2 libxfixes3 \
    libxcomposite1 libxcursor1 libxdamage1 libxkbcommon0 \
    libfreetype6 fontconfig fonts-dejavu fonts-liberation \
    # Display virtual + WM + VNC + noVNC
    xvfb x11-utils xauth fluxbox x11vnc novnc websockify \
    # Electron / Chromium
    libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 libgbm1 \
    libpango-1.0-0 libpangocairo-1.0-0 libcairo2 \
    libnss3 libnspr4 libxshmfence1 libasound2 \
    libgtk-3-0 libglib2.0-0 libgdk-pixbuf-2.0-0 libatspi2.0-0 \
    # Módulos nativos Node/Electron
    libsecret-1-0 libnotify4 libuuid1 \
    # dbus + JRE respaldo
    dbus dbus-x11 \
    openjdk-17-jre-headless \
    && rm -rf /var/lib/apt/lists/* \
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
    && find ${SQX_HOME} -maxdepth 3 -name "StrategyQuantX*" -exec chmod +x {} \; \
    && find ${SQX_HOME} -maxdepth 3 -name "*.sh" -exec chmod +x {} \; \
    && find ${SQX_HOME}/internal/electron -maxdepth 2 -type f -name "strategyquantx_ui*" -exec chmod +x {} \; 2>/dev/null || true

ENV SQ_JVM_XMX=16g

# Entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# noVNC (web), VNC directo, API interna de SQX
EXPOSE 8090 5901 5050

# Healthcheck: verifica que noVNC y x11vnc respondan TCP.
# start_period=2m da tiempo a SQX a arrancar la primera vez.
HEALTHCHECK --interval=30s --timeout=10s --start-period=2m --retries=3 \
    CMD nc -z localhost 5901 && nc -z localhost 8090 || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
