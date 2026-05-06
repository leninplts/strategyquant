#!/bin/bash
# ============================================================
# setup-host-arm64.sh
# ============================================================
# Prepara un host ARM64 (ej. Oracle Cloud Ampere A1) para poder
# construir y correr imagenes Docker x86_64 mediante emulacion
# QEMU + binfmt_misc.
#
# REQUISITO PARA: StrategyQuant X (solo distribuye binarios x86_64).
#
# COMO USAR:
#   1. SSH a tu VM ARM64.
#   2. Copiar este script (o git clone del repo).
#   3. Ejecutar UNA SOLA VEZ:
#        sudo bash setup-host-arm64.sh
#   4. Verificar al final que imprime:  uname -m -> x86_64
#   5. Despues, Dokploy / docker compose build funcionara normal.
#
# Es idempotente: puedes correrlo varias veces sin problema.
# ============================================================

set -e

echo "============================================================"
echo ">>> Setup host ARM64 para emulacion x86_64 (QEMU + binfmt)"
echo "============================================================"

# 1. Comprobar arquitectura del host
HOST_ARCH=$(uname -m)
echo "[1/6] Arquitectura del host: $HOST_ARCH"
if [ "$HOST_ARCH" = "x86_64" ] || [ "$HOST_ARCH" = "amd64" ]; then
    echo "    El host ya es x86_64. No necesitas emulacion. Saliendo."
    exit 0
fi
if [ "$HOST_ARCH" != "aarch64" ] && [ "$HOST_ARCH" != "arm64" ]; then
    echo "    ADVERTENCIA: arquitectura inesperada ($HOST_ARCH). Continuando igualmente..."
fi

# 2. Verificar que somos root
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: este script debe correrse como root (usa sudo)."
    exit 1
fi

# 3. Verificar que docker existe
if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker no esta instalado. Instala docker primero."
    exit 1
fi

# 4. Asegurar binfmt_misc montado
echo "[2/6] Verificando binfmt_misc en el kernel..."
if ! mount | grep -q binfmt_misc; then
    echo "    binfmt_misc no esta montado. Montando..."
    mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true
fi

if ! mount | grep -q binfmt_misc; then
    echo "    ERROR: no se pudo montar binfmt_misc. Tu kernel quizas no lo soporta."
    echo "    Comprueba: zcat /proc/config.gz | grep BINFMT_MISC"
    exit 1
fi

# Persistir el mount en fstab
if ! grep -q binfmt_misc /etc/fstab 2>/dev/null; then
    echo "    Persistiendo binfmt_misc en /etc/fstab..."
    echo "binfmt_misc /proc/sys/fs/binfmt_misc binfmt_misc defaults 0 0" >> /etc/fstab
fi

# 5. Limpiar registros previos por si quedaron de intentos anteriores
echo "[3/6] Limpiando registros binfmt previos..."
# Quitar registros viejos por si quedaron a medias
docker run --privileged --rm tonistiigi/binfmt --uninstall qemu-x86_64 >/dev/null 2>&1 || true
# Vaciar registro del kernel (sobrevive a reinstalar qemu-user-static)
if [ -f /proc/sys/fs/binfmt_misc/qemu-x86_64 ]; then
    echo -1 > /proc/sys/fs/binfmt_misc/qemu-x86_64 2>/dev/null || true
fi

# 6. Reinstalar paquetes oficiales de Ubuntu (24.04 trae qemu 8.2.2 que NO
# tiene el bug del SIGSEGV en MAPERR. Usamos los paquetes nativos del SO
# en lugar de tonistiigi/binfmt porque en Ubuntu 24.04 systemd-binfmt
# sobrescribe registros runtime y choca con tonistiigi.)
echo "[4/6] Instalando qemu-user-static y binfmt-support desde apt..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends --reinstall \
    qemu-user-static binfmt-support

# 7. Activar systemd-binfmt (camino oficial Ubuntu 24.04)
# qemu-user-static instala /usr/lib/binfmt.d/qemu-*.conf
# systemd-binfmt los lee y registra en /proc/sys/fs/binfmt_misc/
echo "[5/6] Activando systemd-binfmt para registrar emuladores..."
if systemctl list-unit-files 2>/dev/null | grep -q systemd-binfmt; then
    systemctl enable systemd-binfmt 2>/dev/null || true
    systemctl restart systemd-binfmt
    sleep 2
fi

# Fallback manual: si systemd-binfmt no registra qemu-x86_64,
# lo registramos directamente desde /usr/lib/binfmt.d/
if [ ! -f /proc/sys/fs/binfmt_misc/qemu-x86_64 ]; then
    echo "    systemd-binfmt no registro qemu-x86_64, registrando manual..."
    if [ -f /usr/lib/binfmt.d/qemu-x86_64.conf ]; then
        # El formato de los .conf es directamente compatible con register
        cat /usr/lib/binfmt.d/qemu-x86_64.conf > /proc/sys/fs/binfmt_misc/register || true
    elif [ -f /var/lib/binfmts/qemu-x86_64 ]; then
        update-binfmts --enable qemu-x86_64 || true
    fi
fi

# 8. Diagnostico previo a la verificacion
echo "[6/6] Verificando emulacion..."
echo "    Registros binfmt actuales:"
ls /proc/sys/fs/binfmt_misc/ 2>/dev/null | sed 's/^/      /'
echo ""
if [ -f /proc/sys/fs/binfmt_misc/qemu-x86_64 ]; then
    echo "    Detalle de qemu-x86_64:"
    cat /proc/sys/fs/binfmt_misc/qemu-x86_64 | sed 's/^/      /'
    echo ""
else
    echo "    AVISO: /proc/sys/fs/binfmt_misc/qemu-x86_64 no existe."
fi

echo "    Verificando version del binario qemu:"
if [ -x /usr/bin/qemu-x86_64-static ]; then
    /usr/bin/qemu-x86_64-static --version | head -1 | sed 's/^/      /'
else
    echo "      WARN: /usr/bin/qemu-x86_64-static no encontrado"
fi
echo ""

echo "    Test de ejecucion (puede tardar 5-10s la primera vez)..."
RESULT=$(docker run --rm --platform linux/amd64 ubuntu:22.04 uname -m 2>&1 || true)
echo "    Resultado: $RESULT"

if echo "$RESULT" | grep -q x86_64; then
    echo "============================================================"
    echo ">>> OK: emulacion x86_64 sobre ARM64 funcionando correctamente"
    echo "============================================================"
    echo ""
    echo "Siguiente paso: en Dokploy, redeploy la app StrategyQuant."
    echo "El build deberia avanzar mas alla del apt-get."
    echo ""
    echo "Recuerda: el primer arranque de SQX bajo emulacion tarda 1-3 min."
    exit 0
else
    echo "============================================================"
    echo ">>> ERROR: la emulacion no quedo activa"
    echo "============================================================"
    echo ""
    echo "Pegame todo el output (incluido el diagnostico de arriba) para diagnosticar."
    exit 1
fi
