#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Regenera dist/SHA256SUMS de forma determinista.
# Uso: scripts/generate-checksums.sh [DIR]
# ---------------------------------------------------------------------------
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

DIR="${1:-$DH_DIST_DIR}"
[[ -d "$DIR" ]] || die "No existe el directorio: $DIR"

dh_need sha256sum
dh_write_checksums "$DIR"

if [[ -n "${DH_GPG_KEY:-}" ]]; then
  "$SCRIPT_DIR/sign.sh" --file "$DIR/SHA256SUMS"
fi
