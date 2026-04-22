#!/bin/bash
set -e

echo "============================================================"
echo ">>> ENTRYPOINT v4 iniciado ($(date))"
echo "============================================================"

cd /opt/sqx

# ---------- Config ----------
export DISPLAY="${DISPLAY:-:1}"
VNC_PORT="${VNC_PORT:-5901}"
NOVNC_PORT="${NOVNC_PORT:-8090}"
VNC_RESOLUTION="${VNC_RESOLUTION:-1600x900}"
VNC_COL_DEPTH="${VNC_COL_DEPTH:-24}"
VNC_PASSWORD="${VNC_PASSWORD:-changeme}"

# ---------- Limpiar locks de X previos ----------
# Si el contenedor reinició, puede quedar /tmp/.X1-lock colgado.
echo ">>> Limpiando locks de X previos..."
rm -f /tmp/.X*-lock /tmp/.X11-unix/X* 2>/dev/null || true
mkdir -p /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix

# ---------- machine-id persistente ----------
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

# ---------- Xvfb ----------
echo ">>> Iniciando Xvfb en $DISPLAY ($VNC_RESOLUTION x $VNC_COL_DEPTH)..."
Xvfb "$DISPLAY" -screen 0 "${VNC_RESOLUTION}x${VNC_COL_DEPTH}" -ac +extension RANDR \
    > /tmp/xvfb.log 2>&1 &
XVFB_PID=$!

for i in $(seq 1 60); do
    if xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
        echo ">>> Xvfb listo tras ${i} intentos."
        break
    fi
    sleep 0.25
done

if ! xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
    echo "ERROR: Xvfb no arrancó. Log:"
    cat /tmp/xvfb.log || true
    exit 1
fi

# ---------- Window manager ----------
echo ">>> Iniciando fluxbox..."
fluxbox >/tmp/fluxbox.log 2>&1 &

# ---------- VNC ----------
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
echo ">>> noVNC corriendo. URL: http://<host>:${NOVNC_PORT}/vnc.html"
echo ">>> VNC password: $VNC_PASSWORD"

# ---------- Buscar GUI ----------
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
    echo "ERROR: no se encontró launcher GUI. Manteniendo noVNC vivo para debug."
    tail -f /dev/null
fi

echo "============================================================"
echo ">>> Launcher GUI: $SQX_BIN"
echo ">>> Abre en navegador: http://<host>:${NOVNC_PORT}/vnc.html"
echo ">>> VNC password: $VNC_PASSWORD"
echo "============================================================"

# ---------- Lanzar GUI en background, capturando logs ----------
# Si crasha, NO queremos que el contenedor se reinicie (porque Dokploy lo
# reiniciará infinitamente). Mantenemos noVNC vivo para poder ver la GUI
# (si al menos arranca la ventana de licencia) o debuggear.
echo ">>> Lanzando GUI..."
(
    export DISPLAY="$DISPLAY"
    cd /opt/sqx
    "$SQX_BIN" > /opt/sqx/logs/gui-stdout.log 2> /opt/sqx/logs/gui-stderr.log
    rc=$?
    echo ">>> GUI terminó con código $rc a $(date)" | tee -a /opt/sqx/logs/gui-stderr.log
) &
GUI_PID=$!

# Pequeña espera y mostrar primeras líneas del log de la GUI si ya hay
sleep 6
echo "---------- GUI stdout (primeras líneas) ----------"
head -80 /opt/sqx/logs/gui-stdout.log 2>/dev/null || echo "(sin stdout aún)"
echo "---------- GUI stderr (primeras líneas) ----------"
head -80 /opt/sqx/logs/gui-stderr.log 2>/dev/null || echo "(sin stderr aún)"
echo "--------------------------------------------------"

# ---------- Mantener contenedor vivo aunque la GUI crashee ----------
# Esperamos a noVNC (principal proceso "servidor"). Si la GUI cae,
# tail del log para que puedas seguir viendo en `docker logs`.
echo ">>> Contenedor listo. Sigue el log de la GUI en vivo:"
tail -F /opt/sqx/logs/gui-stdout.log /opt/sqx/logs/gui-stderr.log 2>/dev/null &

# Esperar indefinidamente
wait "$NOVNC_PID"
