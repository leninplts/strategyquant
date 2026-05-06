# Forzamos plataforma x86_64 porque el binario de StrategyQuantX
# (Electron + JRE empaquetado) solo tiene build oficial para amd64.
# En hosts ARM64 (ej. Oracle Ampere A1) esto requiere qemu-user-static
# + binfmt registrado (ver README/notas de despliegue).
FROM --platform=linux/amd64 ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive \
    SQX_HOME=/opt/sqx \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    DISPLAY=:1 \
    VNC_PORT=5901 \
    NOVNC_PORT=8090 \
    VNC_RESOLUTION=1600x900 \
    VNC_COL_DEPTH=24

# ------------------------------------------------------------
# Fix de keyring para builds amd64 emulados sobre ARM64.
# ------------------------------------------------------------
# La imagen ubuntu:22.04 amd64 trae /etc/apt/trusted.gpg.d/ubuntu-keyring-*.gpg
# en un formato que APT parcheado actual reporta como "unsupported filetype",
# rechazando todos los repos como "not signed".
#
# Fix: descargar archivos .gpg "limpios" desde keyserver y reemplazar.
# Esto NO requiere apt-get update previo y funciona aunque el cache de la
# imagen base esté en estado inconsistente.
#
# Si el host es x86 nativo y los keyrings funcionan, este paso es inocuo
# (re-escribe los mismos archivos validos).
# ------------------------------------------------------------
RUN set -eux; \
    # Borrar keyrings posiblemente corruptos
    rm -f /etc/apt/trusted.gpg.d/ubuntu-keyring-*.gpg; \
    # Permitir bypass GPG SOLO para descargar el paquete oficial ubuntu-keyring.
    # Limitamos a una operacion atomica: bajar el .deb del paquete y dpkg -i.
    # Nada mas se instala bajo bypass.
    printf 'Acquire::AllowInsecureRepositories "true";\nAcquire::AllowDowngradeToInsecureRepositories "true";\nAPT::Get::AllowUnauthenticated "true";\n' \
        > /etc/apt/apt.conf.d/99-temp-insecure; \
    apt-get update; \
    # Solo descargamos (no instalamos aun) el paquete oficial
    cd /tmp && apt-get download ubuntu-keyring; \
    # Instalar via dpkg (no requiere repos firmados)
    dpkg -i /tmp/ubuntu-keyring_*.deb; \
    rm -f /tmp/ubuntu-keyring_*.deb; \
    # Quitar bypass: a partir de aqui, validacion GPG normal
    rm -f /etc/apt/apt.conf.d/99-temp-insecure; \
    # Fix de permisos por si quedaron mal
    chmod 644 /etc/apt/trusted.gpg.d/*.gpg 2>/dev/null || true; \
    # Limpiar listas viejas para forzar re-fetch con keyring nuevo
    rm -rf /var/lib/apt/lists/*; \
    # Validar: este apt-get update DEBE funcionar sin --allow-unauthenticated
    apt-get update

# Paquetes base + X11 + Xvfb/VNC/noVNC + dependencias de Electron
RUN apt-get install -y --no-install-recommends \
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

# Heap JVM. Bajado de 16g -> 12g por el overhead extra de memoria
# que introduce QEMU al emular x86_64 sobre ARM64. Si corres en host
# x86 nativo puedes subirlo de nuevo.
ENV SQ_JVM_XMX=12g

# Entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# noVNC (web), VNC directo, API interna de SQX
EXPOSE 8090 5901 5050

# Healthcheck: verifica que noVNC y x11vnc respondan TCP.
# start_period=5m porque bajo emulación QEMU (ARM64 -> amd64) el
# arranque de Electron + JRE es notablemente más lento que en x86 nativo.
HEALTHCHECK --interval=30s --timeout=10s --start-period=5m --retries=3 \
    CMD nc -z localhost 5901 && nc -z localhost 8090 || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
