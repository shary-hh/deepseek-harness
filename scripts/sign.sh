#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Firma un artefacto con GPG (firma detached, sin passphrase en argumentos).
#
# Uso: DH_GPG_KEY=<fingerprint> scripts/sign.sh --file dist/SHA256SUMS
# ---------------------------------------------------------------------------
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<'EOF'
Firma archivos con GPG (detached ASCII).

Uso: DH_GPG_KEY=<fingerprint> scripts/sign.sh --file ARCHIVO [--file ...]

La passphrase se pide por la terminal de GPG; nunca se pasa por argumentos
ni se guarda en el repositorio. En CI usa un secreto y GPG_FINGERPRINT.
EOF
}

FILES=()
while (($#)); do
  case "$1" in
    --file) FILES+=("${2:?--file requiere un valor}"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Opción desconocida: $1" ;;
  esac
done

((${#FILES[@]} > 0)) || { usage; exit 1; }
dh_need gpg
[[ -n "${DH_GPG_KEY:-}" ]] || die "Define DH_GPG_KEY con el fingerprint de tu clave."

for f in "${FILES[@]}"; do
  [[ -f "$f" ]] || die "No existe: $f"
  log "firmando $(basename -- "$f")"
  if [[ -n "${DH_GPG_PASSPHRASE:-}" ]]; then
    # La passphrase entra por stdin, nunca por argv ni por variable visible.
    printf '%s' "$DH_GPG_PASSPHRASE" | gpg --batch --yes --pinentry-mode loopback \
      --passphrase-fd 0 --local-user "$DH_GPG_KEY" --armor --detach-sign "$f"
  else
    gpg --batch --yes --local-user "$DH_GPG_KEY" --armor --detach-sign "$f"
  fi
  ok "firma: $f.asc"
done
