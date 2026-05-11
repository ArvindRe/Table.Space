#!/bin/bash
# Installer for Datapump Scripts Suite
# Author: Arvind Regukumar
# Deploys all scripts to /export/home/oracle/arvind/ on the target server.

INSTALL_DIR="${1:-/export/home/oracle/arvind}"

echo "Installing Datapump scripts to: ${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}"

# Copy all scripts (excluding this installer)
for f in $(dirname "$0")/*.sh; do
    [[ "$(basename $f)" == "install.sh" ]] && continue
    cp "$f" "${INSTALL_DIR}/"
    chmod +x "${INSTALL_DIR}/$(basename $f)"
    echo "  installed: $(basename $f)"
done

echo ""
echo "Done. ${INSTALL_DIR} contents:"
ls -lh "${INSTALL_DIR}"/*.sh
