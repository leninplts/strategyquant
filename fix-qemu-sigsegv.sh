#!/bin/bash
# ============================================================
# fix-qemu-sigsegv.sh
# ============================================================
# Arregla el SIGSEGV (MAPERR addr=0x20) de QEMU user-mode en
# hosts ARM64 (Oracle Cloud Ampere A1) cuando se intenta emular
# x86_64.
#
# Sintoma:
#   x86_64-binfmt-P: QEMU internal SIGSEGV {code=MAPERR, addr=0x20}
#   Segmentation fault (core dumped)
#
# Causas conocidas:
#   1. mmap_min_addr alto bloquea page=0..mmap_min_addr y QEMU user
#      necesita mapear paginas bajas para emular x86_64.
#   2. Kernel Oracle UEK / kernel ARM64 con CONFIG_ARM64_VA_BITS_52
#      o CONFIG_KASAN: provoca fallos en QEMU < 9.x.
#   3. AppArmor/SELinux bloqueando mmap.
#
# Fixes que intenta este script (sin reboot):
#   1. Bajar mmap_min_addr a 0 (en runtime + persistente).
#   2. Verificar/desactivar AppArmor para QEMU.
#   3. Reiniciar systemd-binfmt y docker.
#   4. Test de emulacion final.
#
# Si tras esto sigue fallando, la unica salida es instalar kernel
# generic Ubuntu (linux-image-generic-hwe-22.04) y hacer reboot.
# ============================================================

set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: este script debe correrse como root (usa sudo)."
    exit 1
fi

echo "============================================================"
echo ">>> Diagnostico y fix de SIGSEGV en QEMU user-mode (ARM64)"
echo "============================================================"

# 1. Info del entorno
echo ""
echo "[1/8] Informacion del kernel y QEMU:"
echo "    Kernel: $(uname -r)"
echo "    Arch:   $(uname -m)"
if [ -r /etc/os-release ]; then
    . /etc/os-release
    echo "    OS:     $PRETTY_NAME"
fi
if [ -x /usr/bin/qemu-x86_64-static ]; then
    echo "    QEMU:   $(/usr/bin/qemu-x86_64-static --version 2>/dev/null | head -1)"
fi

# 2. Verificar mmap_min_addr actual
echo ""
echo "[2/8] Estado actual de mmap_min_addr:"
CURRENT_MMAP=$(cat /proc/sys/vm/mmap_min_addr 2>/dev/null || echo "?")
echo "    /proc/sys/vm/mmap_min_addr = $CURRENT_MMAP"

# 3. Bajar mmap_min_addr a 0 (runtime)
echo ""
echo "[3/8] Bajando mmap_min_addr a 0 (runtime)..."
sysctl -w vm.mmap_min_addr=0
echo "    Nuevo valor: $(cat /proc/sys/vm/mmap_min_addr)"

# 4. Persistir en sysctl.d
echo ""
echo "[4/8] Persistiendo en /etc/sysctl.d/99-qemu-user.conf..."
cat > /etc/sysctl.d/99-qemu-user.conf <<'EOF'
# Permitir a QEMU user-mode mapear paginas bajas necesarias para
# emulacion x86_64 sobre ARM64. Sin esto, QEMU crashea con
# SIGSEGV {MAPERR addr=0x20} al ejecutar binarios x86 simples.
vm.mmap_min_addr = 0
EOF
sysctl --system >/dev/null 2>&1 || true

# 5. AppArmor: liberar QEMU si esta restringido
echo ""
echo "[5/8] Verificando AppArmor sobre QEMU..."
if command -v aa-status >/dev/null 2>&1; then
    if aa-status 2>/dev/null | grep -qi qemu; then
        echo "    AppArmor tiene un perfil sobre QEMU. Poniendolo en 'complain'..."
        for prof in $(aa-status 2>/dev/null | awk '/qemu/ {print $1}'); do
            aa-complain "$prof" 2>/dev/null || true
        done
    else
        echo "    AppArmor no esta restringiendo QEMU. OK."
    fi
else
    echo "    AppArmor no instalado. OK."
fi

# 6. Reiniciar systemd-binfmt y docker para tomar cambios
echo ""
echo "[6/8] Reiniciando systemd-binfmt..."
systemctl restart systemd-binfmt 2>/dev/null || true
sleep 1

# Verificar que qemu-x86_64 sigue registrado
if [ ! -f /proc/sys/fs/binfmt_misc/qemu-x86_64 ]; then
    echo "    AVISO: qemu-x86_64 no esta registrado. Ejecuta primero setup-host-arm64.sh"
    exit 1
fi

echo ""
echo "[7/8] Reiniciando dockerd..."
systemctl restart docker
sleep 3
# Esperar a que docker este listo
for i in 1 2 3 4 5 6 7 8 9 10; do
    if docker info >/dev/null 2>&1; then
        echo "    Docker listo."
        break
    fi
    sleep 1
done

# 7. Test critico: ejecutar grep bajo emulacion (es lo que crashea)
echo ""
echo "[8/8] Test critico de emulacion x86_64:"
echo "    Probando 'uname -m'..."
RESULT_UNAME=$(docker run --rm --platform linux/amd64 ubuntu:22.04 uname -m 2>&1 || true)
echo "    -> $RESULT_UNAME"

echo "    Probando 'grep' (lo que crasheaba antes)..."
RESULT_GREP=$(docker run --rm --platform linux/amd64 ubuntu:22.04 \
    sh -c "echo hello | grep hello" 2>&1 || true)
echo "    -> $RESULT_GREP"

echo "    Probando 'apt-get update' completo..."
RESULT_APT=$(docker run --rm --platform linux/amd64 ubuntu:22.04 \
    sh -c "apt-get update 2>&1 | tail -3" 2>&1 || true)
echo "    -> Output (ultimas 3 lineas):"
echo "$RESULT_APT" | sed 's/^/         /'

echo ""
echo "============================================================"
if echo "$RESULT_UNAME" | grep -q x86_64 && \
   echo "$RESULT_GREP" | grep -q hello && \
   ! echo "$RESULT_APT" | grep -qi 'segmentation\|sigsegv'; then
    echo ">>> OK: QEMU user-mode estable. Procede con el deploy en Dokploy."
    echo "============================================================"
    exit 0
else
    echo ">>> FALLO: QEMU sigue crasheando."
    echo "============================================================"
    echo ""
    echo "Los fixes runtime no bastaron. Tu kernel ARM64 es incompatible"
    echo "con QEMU user-mode. Opciones:"
    echo ""
    echo "  A) Instalar kernel HWE generico de Ubuntu (mas compatible):"
    echo "       sudo apt install -y linux-image-generic-hwe-22.04"
    echo "       sudo reboot"
    echo "     Tras reboot, vuelve a correr setup-host-arm64.sh."
    echo ""
    echo "  B) Migrar SQX a una instancia Oracle x86 (E2.1.Micro free"
    echo "     tier es muy chica; mejor E4.Flex de pago)."
    echo ""
    echo "  C) Usar un image base diferente con qemu mas amigable"
    echo "     (debian:bookworm-slim suele tener menos triggers)."
    echo ""
    exit 1
fi
