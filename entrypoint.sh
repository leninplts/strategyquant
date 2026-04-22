#!/bin/bash
set -e

echo "============================================================"
echo ">>> ENTRYPOINT v3 iniciado ($(date))"
echo "============================================================"

cd /opt/sqx

# ---------- Config ----------
export DISPLAY="${DISPLAY:-:1}"
VNC_PORT="${VNC_PORT:-5901}"
NOVNC_PORT="${NOVNC_PORT:-8090}"
VNC_RESOLUTION="${VNC_RESOLUTION:-1600x900}"
VNC_COL_DEPTH="${VNC_COL_DEPTH:-24}"
VNC_PASSWORD="${VNC_PASSWORD:-changeme}"

# ---------- machine-id persistente ----------
# SQX lee /var/lib/dbus/machine-id para calcular el Hardware ID.
# Si no existe, crashea. Lo persistimos en el volumen /opt/sqx/user
# para que el Hardware ID sea estable aunque reconstruyas la imagen.
mkdir -p /opt/sqx/user
if [ ! -f /opt/sqx/user/.machine-id ]; then
    if [ -s /etc/machine-id ]; then
        cp /etc/machine-id /opt/sqx/user/.machine-id
    else
        dbus-uuidgen > /opt/sqx/user/.machine-id
    fi
    echo ">>> Generado nuevo machine-id persistente."
fi
mkdir -p /var/lib/dbus
cp /opt/sqx/user/.machine-id /etc/machine-id
cp /opt/sqx/user/.machine-id /var/lib/dbus/machine-id
echo ">>> machine-id: $(cat /etc/machine-id)"

# ---------- DEBUG: listar /opt/sqx ----------
echo ">>> Contenido de /opt/sqx:"
ls -la /opt/sqx || true
echo "============================================================"

# ---------- Xvfb ----------
echo ">>> Iniciando Xvfb en $DISPLAY ($VNC_RESOLUTION x $VNC_COL_DEPTH)..."
Xvfb "$DISPLAY" -screen 0 "${VNC_RESOLUTION}x${VNC_COL_DEPTH}" -ac +extension RANDR &
XVFB_PID=$!

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

# ---------- Buscar GUI ----------
# Prioridad: StrategyQuantX > StrategyQuantX_nocheck (modo debug).
# NUNCA sqcli (es el CLI).
SQX_BIN=""
for cand in \
    ./StrategyQuantX \
    ./StrategyQuantX_nocheck \
    ./strategyquantx \
    ./StrategyQuantX.sh \
    ./strategyquantx.sh \
    ./run.sh \
    ./start.sh; do
    if [ -x "$cand" ] && [ "$(basename "$cand")" != "sqcli" ]; then
        SQX_BIN="$cand"
        break
    fi
done

if [ -z "$SQX_BIN" ]; then
    echo "============================================================"
    echo "ERROR: NO se encontró launcher de la GUI."
    echo "Mantengo noVNC vivo para debug."
    echo "============================================================"
    wait "$NOVNC_PID"
    exit 1
fi

echo "============================================================"
echo ">>> Launcher GUI: $SQX_BIN"
echo ">>> Hardware ID se basará en machine-id: $(cat /etc/machine-id)"
echo ">>> Abre en navegador: http://<host>:${NOVNC_PORT}/vnc.html"
echo ">>> VNC password: $VNC_PASSWORD"
echo ">>> La licencia se activa DESDE LA GUI al abrirla (no intento activar por CLI)."
echo "============================================================"

# Lanzar la GUI en primer plano
exec "$SQX_BIN"
