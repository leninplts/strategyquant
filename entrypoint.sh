#!/bin/bash
set -e

cd /opt/sqx

# ---------- Config ----------
export DISPLAY="${DISPLAY:-:1}"
VNC_PORT="${VNC_PORT:-5901}"
NOVNC_PORT="${NOVNC_PORT:-8090}"
VNC_RESOLUTION="${VNC_RESOLUTION:-1600x900}"
VNC_COL_DEPTH="${VNC_COL_DEPTH:-24}"
VNC_PASSWORD="${VNC_PASSWORD:-changeme}"

LICENSE_MARKER="/opt/sqx/user/.license_activated"

# ---------- Licencia ----------
mkdir -p /opt/sqx/user

if [ ! -f "$LICENSE_MARKER" ]; then
    if [ -n "$SQX_LICENSE" ]; then
        echo ">>> Activando licencia SQX..."
        ./sqcli license="$SQX_LICENSE" || echo "WARN: fallo al activar licencia (se intentará de nuevo en próximo arranque si falla)"
        touch "$LICENSE_MARKER"
        echo ">>> Licencia procesada."
    else
        echo ">>> SQX_LICENSE no definida. Podrás activarla desde la GUI al abrirla."
    fi
fi

# ---------- Xvfb (display virtual) ----------
echo ">>> Iniciando Xvfb en $DISPLAY ($VNC_RESOLUTION x $VNC_COL_DEPTH)..."
Xvfb "$DISPLAY" -screen 0 "${VNC_RESOLUTION}x${VNC_COL_DEPTH}" -ac +extension RANDR &
XVFB_PID=$!

# Esperar a que Xvfb esté listo
for i in $(seq 1 20); do
    if xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
        break
    fi
    sleep 0.3
done

# ---------- Window manager ----------
echo ">>> Iniciando fluxbox..."
fluxbox >/tmp/fluxbox.log 2>&1 &

# ---------- VNC server ----------
echo ">>> Configurando contraseña VNC..."
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

# ---------- noVNC (web client) ----------
echo ">>> Iniciando noVNC en puerto $NOVNC_PORT (proxy a VNC $VNC_PORT)..."
websockify --web=/usr/share/novnc/ "$NOVNC_PORT" "localhost:$VNC_PORT" \
    > /tmp/novnc.log 2>&1 &

# ---------- StrategyQuant X ----------
# Buscar el launcher de la GUI (nombre puede variar entre versiones)
SQX_BIN=""
for cand in ./StrategyQuantX ./strategyquantx ./StrategyQuantX.sh ./run.sh; do
    if [ -x "$cand" ]; then
        SQX_BIN="$cand"
        break
    fi
done

if [ -z "$SQX_BIN" ]; then
    echo "ERROR: no se encontró ejecutable de la GUI de StrategyQuant X."
    echo "Contenido de /opt/sqx:"
    ls -la /opt/sqx
    exit 1
fi

echo ">>> Iniciando StrategyQuant X GUI: $SQX_BIN"
echo ">>> Accede desde el navegador: http://<host>:${NOVNC_PORT}/vnc.html  (password: $VNC_PASSWORD)"

# Ejecutar SQX en primer plano para que el contenedor viva con él
exec "$SQX_BIN"
