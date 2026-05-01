#!/bin/bash
# NO `set -e` aqui: queremos que el watchdog siga vivo aunque comandos
# sueltos fallen. Capturamos errores manualmente.

echo "============================================================"
echo ">>> ENTRYPOINT v6 (watchdog) iniciado ($(date))"
echo "============================================================"

cd /opt/sqx

# ------------------------------------------------------------
# Config
# ------------------------------------------------------------
export DISPLAY="${DISPLAY:-:1}"
VNC_PORT="${VNC_PORT:-5901}"
NOVNC_PORT="${NOVNC_PORT:-8090}"
VNC_RESOLUTION="${VNC_RESOLUTION:-1600x900}"
VNC_COL_DEPTH="${VNC_COL_DEPTH:-24}"
VNC_PASSWORD="${VNC_PASSWORD:-changeme}"
WATCHDOG_INTERVAL="${WATCHDOG_INTERVAL:-15}"

LOG_DIR="/opt/sqx/logs"
mkdir -p "$LOG_DIR"
WATCHDOG_LOG="$LOG_DIR/watchdog.log"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg"
    echo "$msg" >> "$WATCHDOG_LOG"
}

# ------------------------------------------------------------
# Trap para apagado limpio (SIGTERM de Docker)
# ------------------------------------------------------------
shutdown() {
    log "SIGTERM recibido, apagando hijos..."
    # Matar todo el grupo de procesos de este script
    pkill -TERM -P $$ 2>/dev/null || true
    sleep 2
    pkill -KILL -P $$ 2>/dev/null || true
    exit 0
}
trap shutdown SIGTERM SIGINT

# ------------------------------------------------------------
# Limpieza inicial
# ------------------------------------------------------------
log "Limpiando locks de X previos..."
rm -f /tmp/.X*-lock /tmp/.X11-unix/X* 2>/dev/null || true
mkdir -p /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix

# ------------------------------------------------------------
# machine-id persistente (Hardware ID estable)
# ------------------------------------------------------------
mkdir -p /opt/sqx/user
if [ ! -f /opt/sqx/user/.machine-id ]; then
    if [ -s /etc/machine-id ]; then
        cp /etc/machine-id /opt/sqx/user/.machine-id
    else
        dbus-uuidgen > /opt/sqx/user/.machine-id
    fi
    log "Generado nuevo machine-id persistente."
fi
mkdir -p /var/lib/dbus
cp /opt/sqx/user/.machine-id /etc/machine-id
cp /opt/sqx/user/.machine-id /var/lib/dbus/machine-id
log "machine-id: $(cat /etc/machine-id)"

# ------------------------------------------------------------
# Revertir wrapper de Electron si quedó de versiones anteriores
# ------------------------------------------------------------
ELECTRON_BIN="/opt/sqx/internal/electron/strategyquantx_ui"
ELECTRON_REAL="/opt/sqx/internal/electron/strategyquantx_ui.real"
if [ -f "$ELECTRON_REAL" ]; then
    log "Revirtiendo wrapper previo de Electron..."
    mv -f "$ELECTRON_REAL" "$ELECTRON_BIN"
    chmod +x "$ELECTRON_BIN"
fi

# ------------------------------------------------------------
# Variables Electron
# ------------------------------------------------------------
export ELECTRON_DISABLE_SANDBOX=1
export ELECTRON_ENABLE_LOGGING=1
export LIBGL_ALWAYS_SOFTWARE=1

# ------------------------------------------------------------
# dbus
# ------------------------------------------------------------
mkdir -p /run/dbus
if [ ! -S /run/dbus/system_bus_socket ]; then
    log "Iniciando dbus-daemon de sistema..."
    dbus-daemon --system --fork 2>/dev/null || log "WARN: dbus system no arrancó"
fi
if [ -z "$DBUS_SESSION_BUS_ADDRESS" ]; then
    eval "$(dbus-launch --sh-syntax 2>/dev/null)" || true
    export DBUS_SESSION_BUS_ADDRESS
fi
log "DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-(no seteado)}"

# ------------------------------------------------------------
# Setup VNC password (una sola vez)
# ------------------------------------------------------------
mkdir -p /root/.vnc
x11vnc -storepasswd "$VNC_PASSWORD" /root/.vnc/passwd >/dev/null 2>&1

# ------------------------------------------------------------
# Detectar launcher SQX (una sola vez)
# ------------------------------------------------------------
SQX_BIN=""
for cand in \
    /opt/sqx/StrategyQuantX \
    /opt/sqx/StrategyQuantX_nocheck \
    /opt/sqx/strategyquantx \
    /opt/sqx/StrategyQuantX.sh \
    /opt/sqx/strategyquantx.sh \
    /opt/sqx/run.sh \
    /opt/sqx/start.sh; do
    if [ -x "$cand" ] && [ "$(basename "$cand")" != "sqcli" ]; then
        SQX_BIN="$cand"
        break
    fi
done

if [ -z "$SQX_BIN" ]; then
    log "ADVERTENCIA: no se encontró launcher GUI de SQX. El watchdog seguirá vivo pero sin SQX."
fi
log "Launcher GUI: ${SQX_BIN:-(ninguno)}"

# ============================================================
# FUNCIONES start_* — cada una arranca un proceso en background
# ============================================================

start_xvfb() {
    log "Iniciando Xvfb en $DISPLAY ($VNC_RESOLUTION x $VNC_COL_DEPTH)..."
    rm -f /tmp/.X*-lock /tmp/.X11-unix/X* 2>/dev/null || true
    Xvfb "$DISPLAY" \
        -screen 0 "${VNC_RESOLUTION}x${VNC_COL_DEPTH}" \
        -ac \
        +extension RANDR \
        +extension GLX \
        -nolisten tcp \
        -dpms \
        -s 0 \
        -noreset \
        > "$LOG_DIR/xvfb.log" 2>&1 &

    # Esperar a que esté listo
    for i in $(seq 1 60); do
        if xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
            log "Xvfb listo tras ${i} intentos."
            # Refuerzo: deshabilitar screensaver/DPMS via xset
            xset -display "$DISPLAY" s off 2>/dev/null || true
            xset -display "$DISPLAY" -dpms 2>/dev/null || true
            xset -display "$DISPLAY" s noblank 2>/dev/null || true
            return 0
        fi
        sleep 0.25
    done
    log "ERROR: Xvfb no respondió tras 15s."
    return 1
}

start_fluxbox() {
    log "Iniciando fluxbox..."
    DISPLAY="$DISPLAY" fluxbox > "$LOG_DIR/fluxbox.log" 2>&1 &
    sleep 1
}

start_x11vnc() {
    log "Iniciando x11vnc en puerto $VNC_PORT (loop interno + ping keepalive)..."
    # x11vnc en foreground (sin -bg) dentro de un subshell con loop
    # para que pgrep -x x11vnc lo vea siempre.
    (
        while true; do
            x11vnc \
                -display "$DISPLAY" \
                -forever \
                -shared \
                -rfbport "$VNC_PORT" \
                -rfbauth /root/.vnc/passwd \
                -noxdamage \
                -noxfixes \
                -noxrandr \
                -xkb \
                -ping 30 \
                -timeout 0 \
                -o "$LOG_DIR/x11vnc.log" \
                2>> "$LOG_DIR/x11vnc.err"
            log "x11vnc terminó con código $?, reiniciando en 3s (loop interno)..."
            sleep 3
        done
    ) &
    sleep 1
}

start_websockify() {
    log "Iniciando websockify (noVNC) en puerto $NOVNC_PORT -> $VNC_PORT..."
    websockify --web=/usr/share/novnc/ "$NOVNC_PORT" "localhost:$VNC_PORT" \
        > "$LOG_DIR/novnc.log" 2>&1 &
    sleep 1
}

start_sqx() {
    if [ -z "$SQX_BIN" ]; then
        return 0
    fi
    log "Lanzando SQX GUI: $SQX_BIN"
    (
        cd /opt/sqx
        DISPLAY="$DISPLAY" "$SQX_BIN" \
            > "$LOG_DIR/gui-stdout.log" \
            2> "$LOG_DIR/gui-stderr.log"
        log "SQX GUI terminó con código $? (será reiniciado por watchdog)"
    ) &
    sleep 2
}

# ============================================================
# Arranque inicial
# ============================================================
start_xvfb
start_fluxbox
start_x11vnc
start_websockify
start_sqx

log "============================================================"
log "Stack iniciado. URL: http://<host>:${NOVNC_PORT}/vnc.html"
log "VNC password: $VNC_PASSWORD"
log "Watchdog activo (intervalo: ${WATCHDOG_INTERVAL}s)"
log "============================================================"

# ============================================================
# Watchdog loop — corazón de la disponibilidad
# ============================================================
# Un tail -F en background para que docker logs vea logs de la GUI tambien
tail -F "$LOG_DIR/gui-stdout.log" "$LOG_DIR/gui-stderr.log" "$LOG_DIR/x11vnc.err" "$WATCHDOG_LOG" 2>/dev/null &

while true; do
    # Xvfb
    if ! pgrep -x Xvfb >/dev/null; then
        log "[WATCHDOG] Xvfb murió — reiniciando..."
        start_xvfb
        # Si Xvfb murió, fluxbox y x11vnc tambien necesitan reset
        pkill -x fluxbox 2>/dev/null || true
        pkill -x x11vnc 2>/dev/null || true
    fi

    # fluxbox
    if ! pgrep -x fluxbox >/dev/null; then
        log "[WATCHDOG] fluxbox murió — reiniciando..."
        start_fluxbox
    fi

    # x11vnc — el subshell con loop debe estar vivo, pero verificamos
    # también el binario en sí (si el loop interno está entre reintentos
    # puede no estar). Verificamos por puerto escuchando.
    if ! pgrep -x x11vnc >/dev/null; then
        # Esperar 2s por si está en sleep entre reintentos
        sleep 2
        if ! pgrep -x x11vnc >/dev/null; then
            log "[WATCHDOG] x11vnc no está vivo — relanzando supervisor..."
            # Matar el loop bash huérfano si quedó
            pkill -f "x11vnc -display" 2>/dev/null || true
            start_x11vnc
        fi
    fi

    # websockify
    if ! pgrep -f "websockify.*${NOVNC_PORT}" >/dev/null; then
        log "[WATCHDOG] websockify murió — reiniciando..."
        start_websockify
    fi

    # SQX GUI
    if [ -n "$SQX_BIN" ]; then
        if ! pgrep -f "$(basename "$SQX_BIN")" >/dev/null; then
            log "[WATCHDOG] SQX GUI no está vivo — reiniciando..."
            start_sqx
        fi
    fi

    sleep "$WATCHDOG_INTERVAL"
done
