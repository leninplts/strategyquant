#!/bin/bash
set -e

cd /opt/sqx

# Marcador para saber si ya activamos
LICENSE_MARKER="/opt/sqx/user/.license_activated"

if [ ! -f "$LICENSE_MARKER" ]; then
    if [ -z "$SQX_LICENSE" ]; then
        echo "ERROR: SQX_LICENSE no está definida. Configurala en Dokploy."
        echo "Hardware ID del container para vincular la licencia:"
        ./sqcli -info 2>/dev/null | grep -i "hardware" || true
        exit 1
    fi

    echo "Activando licencia SQX..."
    ./sqcli license="$SQX_LICENSE"
    
    mkdir -p /opt/sqx/user
    touch "$LICENSE_MARKER"
    echo "Licencia activada."
fi

echo "Iniciando SQX webserver en puerto 8090..."
exec ./sqcli -gui port=8090