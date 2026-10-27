#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Escáner de secretos: falla si encuentra credenciales en el árbol de trabajo.
# Es una red de seguridad, NO sustituye a gitleaks/trufflehog en CI.
#
# Uso: scripts/scan-secrets.sh [DIR]
# ---------------------------------------------------------------------------
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

ROOT="${1:-$REPO_ROOT}"

# Patrones partidos para que este archivo no se detecte a sí mismo.
PATTERNS=(
  "gh""[pousr]_[A-Za-z0-9]{20,}"
  "github""_pat_[A-Za-z0-9_]{20,}"
  "s""k-[A-Za-z0-9]{24,}"
  "AK""IA[0-9A-Z]{16}"
  "-----BEGIN [A-Z ]*PRIVATE KEY-----"
  "xo""x[baprs]-[A-Za-z0-9-]{10,}"
  "AI""za[0-9A-Za-z_-]{35}"
  "gl""pat-[A-Za-z0-9_-]{20,}"
  "np""m_[A-Za-z0-9]{36}"
)

FOUND=0
for pattern in "${PATTERNS[@]}"; do
  hits="$(grep -rInE --binary-files=without-match \
    --exclude-dir=.git --exclude-dir=dist --exclude-dir=build \
    --exclude-dir=node_modules --exclude=scan-secrets.sh \
    --exclude=SHA256SUMS --exclude='*.asc' \
    -- "$pattern" "$ROOT" 2>/dev/null || true)"
  if [[ -n "$hits" ]]; then
    printf '%s\n' "$hits" | dh_redact >&2
    FOUND=1
  fi
done

# Nombres de archivo peligrosos que no deberían estar versionados.
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  printf 'archivo sensible: %s\n' "$f" >&2
  FOUND=1
done < <(find "$ROOT" -path "$ROOT/.git" -prune -o \
  \( -name '.env' -o -name '.env.*' -o -name '*.pem' -o -name '*.key' \
     -o -name 'id_rsa' -o -name 'id_ed25519' -o -name '.npmrc' \) \
  ! -name '.env.example' ! -name '.env.sample' \
  -type f -print 2>/dev/null || true)

if [[ "$FOUND" == "1" ]]; then
  die "Se encontraron posibles secretos. Revísalos antes de hacer commit/push."
fi
ok "sin secretos detectados"
