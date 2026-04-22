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

# ---------- Wrap de Electron para forzar --no-sandbox ----------
# Electron necesita --no-sandbox en contenedores sin SYS_ADMIN/userns.
# SQX llama al binario directamente, así que lo reemplazamos con un wrapper.
ELECTRON_BIN="/opt/sqx/internal/electron/strategyquantx_ui"
ELECTRON_REAL="/opt/sqx/internal/electron/strategyquantx_ui.real"
if [ -f "$ELECTRON_BIN" ] && [ ! -f "$ELECTRON_REAL" ]; then
    echo ">>> Creando wrapper de Electron con --no-sandbox..."
    mv "$ELECTRON_BIN" "$ELECTRON_REAL"
    cat > "$ELECTRON_BIN" << 'WRAP'
#!/bin/bash
exec /opt/sqx/internal/electron/strategyquantx_ui.real \
    --no-sandbox \
    --disable-gpu \
    --disable-dev-shm-usage \
    --disable-software-rasterizer \
    "$@"
WRAP
    chmod +x "$ELECTRON_BIN"
fi
# Variables de entorno para Electron
export ELECTRON_DISABLE_SANDBOX=1
export ELECTRON_ENABLE_LOGGING=1

# ---------- Diagnóstico de entorno ----------
echo ">>> Diagnóstico:"
echo "    Usuario: $(id)"
echo "    /tmp permisos: $(ls -ld /tmp)"
echo "    /tmp/.X11-unix: $(ls -ld /tmp/.X11-unix 2>/dev/null || echo 'no existe')"
echo "    /dev/shm: $(ls -ld /dev/shm 2>/dev/null || echo 'no existe')"
echo "    /dev/shm size: $(df -h /dev/shm 2>/dev/null | tail -1 || echo 'n/a')"
echo "    which Xvfb: $(which Xvfb)"
echo "    Xvfb version: $(Xvfb -version 2>&1 | head -3 || true)"

# ---------- Xvfb ----------
echo ">>> Iniciando Xvfb en $DISPLAY ($VNC_RESOLUTION x $VNC_COL_DEPTH)..."
# Primero intento en foreground para capturar cualquier error
Xvfb "$DISPLAY" -screen 0 "${VNC_RESOLUTION}x${VNC_COL_DEPTH}" -ac +extension RANDR \
    +extension GLX -nolisten tcp \
    > /tmp/xvfb.log 2>&1 &
XVFB_PID=$!

# Dar tiempo inicial
sleep 2

# Ver si el proceso sigue vivo
if ! kill -0 "$XVFB_PID" 2>/dev/null; then
    echo "ERROR: Xvfb murió inmediatamente. Log completo:"
    echo "----- /tmp/xvfb.log -----"
    cat /tmp/xvfb.log 2>&1 || echo "(log vacío o inaccesible)"
    echo "----- fin log -----"
    echo "----- intentando arrancar en foreground para ver error directo -----"
    Xvfb "$DISPLAY" -screen 0 "${VNC_RESOLUTION}x${VNC_COL_DEPTH}" -ac 2>&1 | head -30 || true
    echo "----- fin -----"
    echo ">>> Manteniendo contenedor vivo para debug (tail -f)..."
    tail -f /dev/null
fi

for i in $(seq 1 60); do
    if xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
        echo ">>> Xvfb listo tras ${i} intentos."
        break
    fi
    sleep 0.25
done

if ! xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
    echo "ERROR: Xvfb arrancó pero no responde. Log:"
    cat /tmp/xvfb.log 2>&1 || true
    echo ">>> Manteniendo contenedor vivo para debug..."
    tail -f /dev/null
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
