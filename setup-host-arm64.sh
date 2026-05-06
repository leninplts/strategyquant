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

# 5. Instalar paquetes necesarios
echo "[3/6] Instalando qemu-user-static y binfmt-support..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends qemu-user-static binfmt-support

# 6. Limpiar TODOS los registros previos de qemu (pueden ser viejos/buggy)
echo "[4/6] Limpiando registros binfmt previos de qemu-x86_64..."
docker run --privileged --rm tonistiigi/binfmt --uninstall qemu-x86_64 >/dev/null 2>&1 || true
# Tambien quitar el qemu-user-static que apt instalo (suele ser version vieja
# con bugs de SIGSEGV al ejecutar post-install scripts de Ubuntu 22.04 amd64)
apt-get remove -y --purge qemu-user-static 2>/dev/null || true

# 7. Registrar amd64 con QEMU MODERNO (8.x+) via tonistiigi/binfmt
# IMPORTANTE: usar tag "qemu-v8.1.5" o superior. La version "latest" a veces
# trae qemu 7.x que tiene bugs con apt-get install de Ubuntu 22.04 amd64.
# Sintoma del bug: "x86_64-binfmt-P: QEMU internal SIGSEGV {code=MAPERR}"
echo "[5/6] Registrando emulador amd64 con QEMU 8.x (estable para Ubuntu 22.04)..."
docker run --privileged --rm tonistiigi/binfmt:qemu-v8.1.5 --install amd64

# Habilitar systemd-binfmt si existe (para que sobreviva reboots de forma limpia)
if systemctl list-unit-files 2>/dev/null | grep -q systemd-binfmt; then
    systemctl enable systemd-binfmt 2>/dev/null || true
    systemctl restart systemd-binfmt 2>/dev/null || true
fi

# 8. Verificar funcionamiento
echo "[6/6] Verificando emulacion (puede tardar la primera vez)..."
RESULT=$(docker run --rm --platform linux/amd64 ubuntu:22.04 uname -m 2>&1 || true)
echo "    Resultado: $RESULT"

if echo "$RESULT" | grep -q x86_64; then
    echo "============================================================"
    echo ">>> OK: emulacion x86_64 sobre ARM64 funcionando correctamente"
    echo "============================================================"
    echo ""
    echo "Siguiente paso: en Dokploy, redeploy la app StrategyQuant."
    echo "El build deberia avanzar mas alla del paso [2/6] apt-get."
    echo ""
    echo "Recuerda: el primer arranque de SQX bajo emulacion tarda 1-3 min."
    exit 0
else
    echo "============================================================"
    echo ">>> ERROR: la emulacion no quedo activa"
    echo "============================================================"
    echo ""
    echo "Diagnostico:"
    echo "  ls /proc/sys/fs/binfmt_misc/"
    ls /proc/sys/fs/binfmt_misc/ 2>/dev/null || echo "  (vacio o no existe)"
    echo ""
    echo "Si /proc/sys/fs/binfmt_misc/ no tiene 'qemu-x86_64', el registro fallo."
    echo "Reporta el output completo."
    exit 1
fi
