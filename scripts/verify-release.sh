#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Verifica artefactos descargados antes de instalarlos.
#
# Uso: scripts/verify-release.sh [--dir dist] [--signature] [--key pub.asc]
# ---------------------------------------------------------------------------
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<'EOF'
Verifica SHA256SUMS y, opcionalmente, la firma GPG.

Uso: scripts/verify-release.sh [opciones]

  --dir DIR        Directorio con los artefactos (por defecto: dist)
  --signature      Exige y verifica SHA256SUMS.asc
  --key FILE       Importa la clave pública en un keyring temporal
  -h, --help       Ayuda
EOF
}

DIR="$DH_DIST_DIR"; NEED_SIG=0; KEY=""
while (($#)); do
  case "$1" in
    --dir) DIR="${2:?--dir requiere un valor}"; shift 2 ;;
    --signature) NEED_SIG=1; shift ;;
    --key) KEY="${2:?--key requiere un valor}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Opción desconocida: $1" ;;
  esac
done

[[ -d "$DIR" ]] || die "No existe el directorio: $DIR"
[[ -f "$DIR/SHA256SUMS" ]] || die "Falta $DIR/SHA256SUMS"
dh_need sha256sum

log "verificando checksums en $DIR"
( cd "$DIR" && sha256sum -c --strict SHA256SUMS )

if [[ "$NEED_SIG" == "1" ]]; then
  dh_need gpg
  [[ -f "$DIR/SHA256SUMS.asc" ]] || die "Falta $DIR/SHA256SUMS.asc"

  if [[ -n "$KEY" ]]; then
    [[ -f "$KEY" ]] || die "No existe la clave: $KEY"
    TMPGNUPG="$(mktemp -d "${TMPDIR:-/tmp}/dh-gpg.XXXXXX")"
    chmod 0700 "$TMPGNUPG"
    # shellcheck disable=SC2064
    trap "rm -rf -- '$TMPGNUPG'" EXIT
    GNUPGHOME="$TMPGNUPG" gpg --batch --quiet --import "$KEY"
    GNUPGHOME="$TMPGNUPG" gpg --batch --verify "$DIR/SHA256SUMS.asc" "$DIR/SHA256SUMS"
  else
    gpg --batch --verify "$DIR/SHA256SUMS.asc" "$DIR/SHA256SUMS"
  fi
  ok "firma GPG válida"
fi

ok "release verificada"
