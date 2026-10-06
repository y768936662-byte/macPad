#!/bin/bash
# Run as root on the rootless iPad. All five tools, manifest and validation
# helpers must be beside this script; no unsigned or partially trusted fallback.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[ "$#" -le 1 ] || { echo "Usage: bash $0 [pkg_dir]" >&2; exit 64; }
exec /var/jb/usr/bin/python3 "$SCRIPT_DIR/install_macws_tools.py" "${1:-$SCRIPT_DIR}"
