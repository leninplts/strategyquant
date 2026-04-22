#!/bin/bash
set -e

echo "============================================================"
echo ">>> ENTRYPOINT v2 iniciado ($(date))"
echo "============================================================"

cd /opt/sqx

# ---------- Config ----------
export DISPLAY="${DISPLAY:-:1}"
VNC_PORT="${VNC_PORT:-5901}"
NOVNC_PORT="${NOVNC_PORT:-8090}"
VNC_RESOLUTION="${VNC_RESOLUTION:-1600x900}"
VNC_COL_DEPTH="${VNC_COL_DEPTH:-24}"
VNC_PASSWORD="${VNC_PASSWORD:-changeme}"

LICENSE_MARKER="/opt/sqx/user/.license_activated"

# ---------- DEBUG: listar contenido de /opt/sqx ----------
echo ">>> Contenido de /opt/sqx:"
ls -la /opt/sqx || true
echo ">>> Ejecutables encontrados (depth <= 3):"
find /opt/sqx -maxdepth 3 -type f \( -perm -u+x -o -name "*.sh" \) 2>/dev/null | head -50 || true
echo "============================================================"

# ---------- Xvfb ----------
echo ">>> Iniciando Xvfb en $DISPLAY ($VNC_RESOLUTION x $VNC_COL_DEPTH)..."
Xvfb "$DISPLAY" -screen 0 "${VNC_RESOLUTION}x${VNC_COL_DEPTH}" -ac +extension RANDR &
XVFB_PID=$!

# Esperar a que Xvfb esté listo
for i in $(seq 1 40); do
    if xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
        echo ">>> Xvfb listo tras ${i} intentos."
        break
    fi
    sleep 0.25
done

# ---------- Window manager ----------
echo ">>> Iniciando fluxbox..."
fluxbox >/tmp/fluxbox.log 2>&1 &

# ---------- VNC server ----------
mkdir -p /root/.vnc
x11vnc -storepasswd "$VNC_PASSWORD" /root/.vnc/passwd >/dev/null 2>&1
echo ">>> Iniciando x11vnc en puerto $VNC_PORT..."
x11vnc -display "$DISPLAY" \
    -forever \
    -shared \
    -rfbport "$VNC_PORT" \
    -rfbauth /root/.vnc/passwd \
    -noxdamage \
    -bg \
    -o /tmp/x11vnc.log

# ---------- noVNC ----------
echo ">>> Iniciando noVNC en puerto $NOVNC_PORT (proxy -> VNC $VNC_PORT)..."
websockify --web=/usr/share/novnc/ "$NOVNC_PORT" "localhost:$VNC_PORT" \
    > /tmp/novnc.log 2>&1 &
NOVNC_PID=$!
sleep 1
echo ">>> noVNC corriendo. Abrir: http://<host>:${NOVNC_PORT}/vnc.html"
echo ">>> VNC password: $VNC_PASSWORD"

# ---------- Activación de licencia (solo si hace falta) ----------
mkdir -p /opt/sqx/user
if [ ! -f "$LICENSE_MARKER" ] && [ -n "$SQX_LICENSE" ] && [ -x "./sqcli" ]; then
    echo ">>> Activando licencia SQX vía sqcli..."
    ./sqcli license="$SQX_LICENSE" || echo "WARN: fallo al activar licencia"
    touch "$LICENSE_MARKER"
fi

# ---------- Buscar GUI de StrategyQuant X ----------
# Excluimos explícitamente sqcli (que es el CLI).
SQX_BIN=""
for cand in \
    ./StrategyQuantX \
    ./strategyquantx \
    ./StrategyQuantX.sh \
    ./strategyquantx.sh \
    ./run.sh \
    ./start.sh \
    ./sqx \
    ./SQX; do
    if [ -x "$cand" ] && [ "$(basename "$cand")" != "sqcli" ]; then
        SQX_BIN="$cand"
        break
    fi
done

# Si no hay launcher dedicado, buscar recursivamente cualquier ejecutable
# cuyo nombre contenga "StrategyQuant" (pero NO sqcli)
if [ -z "$SQX_BIN" ]; then
    SQX_BIN=$(find /opt/sqx -maxdepth 4 -type f -iname "*strategyquant*" \
              ! -iname "*sqcli*" -perm -u+x 2>/dev/null | head -1)
fi

if [ -z "$SQX_BIN" ]; then
    echo "============================================================"
    echo "ERROR: NO se encontró launcher de la GUI."
    echo "Mantengo Xvfb+VNC+noVNC vivos para que puedas conectar y debuggear."
    echo "Abre http://<host>:${NOVNC_PORT}/vnc.html y verás escritorio vacío."
    echo "============================================================"
    # Mantener contenedor vivo
    wait "$NOVNC_PID"
    exit 1
fi

echo "============================================================"
echo ">>> Lanzador GUI detectado: $SQX_BIN"
echo ">>> Abre en navegador: http://<host>:${NOVNC_PORT}/vnc.html"
echo ">>> VNC password: $VNC_PASSWORD"
echo "============================================================"

# Ejecutar SQX GUI en primer plano
exec "$SQX_BIN"
