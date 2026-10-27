#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Pruebas locales: sintaxis, shellcheck, secretos y build real del .deb con
# un payload de prueba. No requiere red (usa --system-node).
#
# Uso: tests/run-tests.sh [--with-exe]
# ---------------------------------------------------------------------------
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=../scripts/lib/common.sh
. "$ROOT/scripts/lib/common.sh"

WITH_EXE=0
[[ "${1:-}" == "--with-exe" ]] && WITH_EXE=1

PASS=0; FAIL=0
declare -a FAILED=()

TMP="$(mktemp -d "${TMPDIR:-/tmp}/dh-test.XXXXXX")"
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT

pass() { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { FAIL=$((FAIL+1)); FAILED+=("$*"); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

section() { printf '\n\033[1m%s\033[0m\n' "$*"; }

section "1. Sintaxis bash"
while IFS= read -r f; do
  if bash -n "$f" 2>/dev/null; then pass "bash -n ${f#"$ROOT"/}"; else fail "bash -n ${f#"$ROOT"/}"; fi
done < <(find "$ROOT/scripts" -name '*.sh' -type f; printf '%s\n' "$ROOT/install.sh" "$ROOT/uninstall.sh")

section "2. shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -x -S warning "$ROOT"/scripts/*.sh "$ROOT"/scripts/lib/*.sh \
      "$ROOT/install.sh" "$ROOT/uninstall.sh"; then
    pass "shellcheck"
  else
    fail "shellcheck"
  fi
else
  printf '  (omitido: shellcheck no instalado)\n'
fi

section "3. Secretos"
if "$ROOT/scripts/scan-secrets.sh" >/dev/null 2>&1; then pass "scan-secrets"; else fail "scan-secrets"; fi

section "4. CLI + web + workspace (mocks, sin red real)"
if command -v node >/dev/null 2>&1; then
  if ( cd "$ROOT" && node --test tests/ >"$TMP/cli.log" 2>&1 ); then
    pass "node --test tests/"
  else
    fail "node --test tests/"
    tail -40 "$TMP/cli.log" >&2
  fi
else
  printf '  (omitido: node no instalado)\n'
fi

section "5. Paquete .deb (payload de prueba, node del sistema)"
APP_FIXTURE="$ROOT/tests/fixtures/app"

if DH_APP_DIR="$APP_FIXTURE" "$ROOT/scripts/build-deb.sh" \
    --system-node --app-dir "$APP_FIXTURE" --output-dir "$TMP" --version 0.1.0 >"$TMP/build.log" 2>&1; then
  pass "build-deb.sh"
else
  fail "build-deb.sh"
  sed -n '1,80p' "$TMP/build.log" >&2
fi

DEB="$(find "$TMP" -maxdepth 1 -name '*.deb' | head -n1)"
if [[ -n "$DEB" ]]; then
  pass "artefacto .deb generado"
  if dpkg-deb --info "$DEB" >/dev/null 2>&1; then pass "dpkg-deb --info"; else fail "dpkg-deb --info"; fi
  if dpkg-deb -c "$DEB" | grep -q './opt/deepseek-harness/bin/deepseek-harness'; then
    pass "layout /opt/deepseek-harness"
  else
    fail "layout /opt/deepseek-harness"
  fi
  mkdir -p "$TMP/root"
  dpkg-deb -x "$DEB" "$TMP/root"
  if [[ "$("$TMP/root/opt/deepseek-harness/bin/deepseek-harness" --version)" == "0.1.0" ]]; then
    pass "el binario empaquetado responde --version"
  else
    fail "el binario empaquetado responde --version"
  fi
else
  fail "artefacto .deb generado"
fi

section "6. Staging de AppImage y Windows"
if DH_APP_DIR="$APP_FIXTURE" "$ROOT/scripts/build-appimage.sh" \
    --system-node --app-dir "$APP_FIXTURE" --output-dir "$TMP" --stage-only >/dev/null 2>&1; then
  pass "build-appimage.sh --stage-only"
else
  fail "build-appimage.sh --stage-only"
fi

if [[ "$WITH_EXE" == "1" ]]; then
  if DH_APP_DIR="$APP_FIXTURE" "$ROOT/scripts/build-exe.sh" \
      --app-dir "$APP_FIXTURE" --output-dir "$TMP" --stage-only >/dev/null 2>&1; then
    pass "build-exe.sh --stage-only (descarga node.exe)"
  else
    fail "build-exe.sh --stage-only"
  fi
fi

section "7. Instalador (dry-run)"
if "$ROOT/install.sh" --from-source --user --dry-run --yes >/dev/null 2>&1; then
  pass "install.sh --dry-run"
else
  fail "install.sh --dry-run"
fi

section "8. RPM (si rpmbuild está disponible)"
if command -v rpmbuild >/dev/null 2>&1; then
  if DH_APP_DIR="$APP_FIXTURE" "$ROOT/scripts/build-rpm.sh" \
      --system-node --app-dir "$APP_FIXTURE" --output-dir "$TMP" --version 0.1.0 >"$TMP/rpm.log" 2>&1; then
    pass "build-rpm.sh"
  else
    fail "build-rpm.sh"
    sed -n '1,80p' "$TMP/rpm.log" >&2
  fi
else
  printf '  (omitido: rpmbuild no instalado)\n'
fi

printf '\n%s\n' "────────────────────────────────────────"
printf 'Resultado: %d correctas, %d fallidas\n' "$PASS" "$FAIL"
if ((FAIL > 0)); then
  printf 'Fallidas:\n'; printf '  - %s\n' "${FAILED[@]}"
  exit 1
fi
