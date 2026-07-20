#!/usr/bin/env bash
set -euo pipefail

# Combines an arm64 and an x86_64 smartctl into a single universal binary and
# installs it as the app's bundled backend, so releases also work on Intel Macs
# (otherwise the bundled smartctl is arm64-only and Intel falls back to a
# Homebrew/system smartctl, if any).
#
# Obtain the two slices from smartmontools builds, e.g. Homebrew on each arch:
#   arm64 : /opt/homebrew/bin/smartctl
#   x86_64: /usr/local/bin/smartctl        (Intel Homebrew)
#
# Usage: Scripts/make_universal_smartctl.sh <arm64-smartctl> <x86_64-smartctl>

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT_DIR/Sources/CheckMyDisk/Resources/Smartctl/smartctl"

fail() { echo "Error: $*" >&2; exit 1; }

[[ $# -eq 2 ]] || fail "Uso: Scripts/make_universal_smartctl.sh <arm64-smartctl> <x86_64-smartctl>"
ARM64_BIN="$1"
X86_64_BIN="$2"
[[ -f "$ARM64_BIN" ]] || fail "No existe el binario arm64: $ARM64_BIN"
[[ -f "$X86_64_BIN" ]] || fail "No existe el binario x86_64: $X86_64_BIN"

command -v lipo >/dev/null 2>&1 || fail "No se encontró 'lipo' en PATH."

[[ " $(lipo -archs "$ARM64_BIN") " == *" arm64 "* ]] || fail "$ARM64_BIN no contiene arm64."
[[ " $(lipo -archs "$X86_64_BIN") " == *" x86_64 "* ]] || fail "$X86_64_BIN no contiene x86_64."

lipo -create "$ARM64_BIN" "$X86_64_BIN" -output "$DEST"
chmod +x "$DEST"

echo "smartctl universal instalado en: $DEST"
echo "Arquitecturas: $(lipo -archs "$DEST")"
