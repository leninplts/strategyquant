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
# Fix definitivo de APT para builds amd64 emulados sobre ARM64.
# ------------------------------------------------------------
# Sintoma persistente:
#   "key(s) in the keyring /etc/apt/trusted.gpg.d/ubuntu-keyring-*.gpg
#    are ignored as the file has an unsupported filetype"
# Esto ocurre incluso tras reinstalar el paquete ubuntu-keyring via dpkg.
#
# Causa raiz: bajo emulacion QEMU x86_64-on-aarch64, el binario gpgv
# (2.2.x de jammy) tiene problemas leyendo el formato binario de los
# keyrings .gpg incluso aunque los archivos esten correctos.
#
# Fix definitivo (estandar moderno de Debian/Ubuntu):
#   1. Bajar las llaves publicas de Ubuntu en formato ASCII (.asc) desde
#      keyserver.ubuntu.com via HTTPS.
#   2. Convertirlas a keyrings binarios "limpios" usando gpg dearmor.
#   3. Reescribir /etc/apt/sources.list usando "signed-by=" para anclar
#      cada repo a su keyring especifico (recomendacion oficial APT 2.x).
#
# Esto evita por completo gpgv leyendo los .gpg legacy.
# ------------------------------------------------------------
RUN set -eux; \
    # Activar bypass GPG global para todo este paso
    printf 'APT::Get::AllowUnauthenticated "true";\nAcquire::AllowInsecureRepositories "true";\nAcquire::AllowDowngradeToInsecureRepositories "true";\n' \
        > /etc/apt/apt.conf.d/99-temp-insecure; \
    # Quitar keyrings legacy que confunden a gpgv bajo QEMU
    rm -f /etc/apt/trusted.gpg.d/ubuntu-keyring-*.gpg; \
    rm -f /etc/apt/trusted.gpg /etc/apt/trusted.gpg.d/*.gpg~ 2>/dev/null || true; \
    # Bajar e instalar gnupg2/curl/ca-certs sin verificacion (en este paso unico)
    apt-get update; \
    apt-get install -y --no-install-recommends --allow-unauthenticated \
        gnupg2 curl ca-certificates; \
    # Crear directorio moderno para keyrings con signed-by
    install -d -m 0755 /etc/apt/keyrings; \
    # Bajar la llave publica de Ubuntu Archive desde keyserver oficial.
    # Key ID: 871920D1991BC93C (Ubuntu Archive Automatic Signing Key 2018).
    # Reintentos por si keyserver tarda o falla momentaneamente.
    for attempt in 1 2 3 4 5; do \
        if curl -fsSL --max-time 30 \
            "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x871920D1991BC93C" \
            -o /tmp/ubuntu-archive.asc; then \
            if [ -s /tmp/ubuntu-archive.asc ] && \
               grep -q 'BEGIN PGP PUBLIC KEY' /tmp/ubuntu-archive.asc; then \
                break; \
            fi; \
        fi; \
        echo "Reintento $attempt: keyserver.ubuntu.com no respondio bien..."; \
        sleep 3; \
    done; \
    # Verificar que tenemos un .asc valido
    test -s /tmp/ubuntu-archive.asc; \
    grep -q 'BEGIN PGP PUBLIC KEY' /tmp/ubuntu-archive.asc; \
    # Convertir ASCII armored -> keyring binario en path nuevo
    gpg --dearmor < /tmp/ubuntu-archive.asc > /etc/apt/keyrings/ubuntu-archive.gpg; \
    rm -f /tmp/ubuntu-archive.asc; \
    chmod 644 /etc/apt/keyrings/ubuntu-archive.gpg; \
    # Reescribir sources.list anclando todos los repos al keyring nuevo
    { \
      echo "deb [signed-by=/etc/apt/keyrings/ubuntu-archive.gpg] http://archive.ubuntu.com/ubuntu/ jammy main restricted universe multiverse"; \
      echo "deb [signed-by=/etc/apt/keyrings/ubuntu-archive.gpg] http://archive.ubuntu.com/ubuntu/ jammy-updates main restricted universe multiverse"; \
      echo "deb [signed-by=/etc/apt/keyrings/ubuntu-archive.gpg] http://archive.ubuntu.com/ubuntu/ jammy-backports main restricted universe multiverse"; \
      echo "deb [signed-by=/etc/apt/keyrings/ubuntu-archive.gpg] http://security.ubuntu.com/ubuntu/ jammy-security main restricted universe multiverse"; \
    } > /etc/apt/sources.list; \
    rm -f /etc/apt/sources.list.d/ubuntu.sources; \
    # Quitar bypass: a partir de aqui apt valida GPG con keyring nuevo
    rm -f /etc/apt/apt.conf.d/99-temp-insecure; \
    rm -rf /var/lib/apt/lists/*; \
    # Validacion final: este apt-get update DEBE pasar firma GPG con la
    # llave que descargamos del keyserver. Si falla, falla el build.
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
