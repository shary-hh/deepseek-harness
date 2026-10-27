#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Construye un paquete .rpm para Fedora / RHEL.
#
# Uso: scripts/build-rpm.sh [opciones]
# ---------------------------------------------------------------------------
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/node.sh
. "$SCRIPT_DIR/lib/node.sh"
# shellcheck source=lib/payload.sh
. "$SCRIPT_DIR/lib/payload.sh"

usage() {
  cat <<'EOF'
Construye un paquete .rpm para Fedora / RHEL.

Uso: scripts/build-rpm.sh [opciones]

  --version VERSION     Versión del paquete (por defecto: ./VERSION)
  --arch ARCH           x86_64 | aarch64 (por defecto: host)
  --app-dir DIR         Payload a empaquetar (por defecto: ./app)
  --output-dir DIR      Destino del .rpm (por defecto: ./dist)
  --system-node         Depende de nodejs del sistema en lugar de empaquetarlo
  --allow-sensitive     No abortar si el payload tiene .env/*.pem/etc.
  --stage-only          Solo preparar el árbol y el spec
  -h, --help            Ayuda

Requiere rpmbuild. En Linux Mint: sudo apt install rpm
EOF
}

VERSION=""; ARCH=""; MODE="bundled"; STAGE_ONLY=0

while (($#)); do
  case "$1" in
    --version)     VERSION="${2:?--version requiere un valor}"; shift 2 ;;
    --arch)        ARCH="${2:?--arch requiere un valor}"; shift 2 ;;
    --app-dir)     export DH_APP_DIR="${2:?--app-dir requiere un valor}"; shift 2 ;;
    --output-dir)  DH_DIST_DIR="${2:?--output-dir requiere un valor}"; shift 2 ;;
    --system-node) MODE="system"; shift ;;
    --allow-sensitive) export DH_ALLOW_SENSITIVE=1; shift ;;
    --stage-only)  STAGE_ONLY=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             die "Opción desconocida: $1" ;;
  esac
done

[[ -n "$VERSION" ]] && export DH_VERSION="$VERSION"
DH_ARCH="$(dh_norm_arch "$ARCH")"
export DH_ARCH

dh_banner "paquete .rpm"
dh_need tar gzip python3
dh_warn_placeholder
dh_prepare_dirs

VERSION="$(dh_version)"
RPM_ARCH="$DH_ARCH"
HOST_ARCH="$(dh_norm_arch)"
[[ "$RPM_ARCH" == "$HOST_ARCH" ]] || die "Cross-build RPM no soportado ($RPM_ARCH en $HOST_ARCH). Usa un runner nativo."

TOP="$DH_BUILD_DIR/rpm"
PAYLOAD="$TOP/SOURCES/payload"
SPEC="$TOP/SPECS/$APP_NAME.spec"

rm -rf -- "$TOP"
mkdir -p "$TOP"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}

dh_stage_payload "$PAYLOAD" "$MODE"
rm -rf -- "$PAYLOAD/share"

install -m 0644 "$REPO_ROOT/packaging/common/$APP_BIN.1" "$TOP/SOURCES/$APP_BIN.1"
install -m 0644 "$REPO_ROOT/LICENSE" "$TOP/SOURCES/LICENSE"

if [[ "$MODE" == "system" ]]; then
  REQUIRES=$'Requires:       nodejs >= 22.19\nRequires:       ca-certificates'
else
  REQUIRES=$'Requires:       glibc >= 2.28\nRequires:       libgcc\nRequires:       libstdc++'
fi

sed -e "s|@APP_NAME@|$APP_NAME|g" \
    -e "s|@APP_BIN@|$APP_BIN|g" \
    -e "s|@VERSION@|$VERSION|g" \
    -e "s|@SUMMARY@|$APP_DESC|g" \
    -e "s|@LICENSE@|$APP_LICENSE|g" \
    -e "s|@URL@|$(dh_homepage)|g" \
    -e "s|@MAINTAINER@|$APP_MAINTAINER|g" \
    -e "s|@LONG@|$APP_LONG_DESC|g" \
    -e "s|@CHANGELOG_DATE@|$(LC_ALL=C date -u '+%a %b %d %Y')|g" \
    "$REPO_ROOT/packaging/rpm/deepseek-harness.spec.in" > "$SPEC"

# Inyecta los Requires (multi-línea) después de AutoReqProv.
python3 - "$SPEC" "$REQUIRES" <<'PY'
import sys
path, requires = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as fh:
    lines = fh.read().splitlines()
out = []
for line in lines:
    out.append(line)
    if line.startswith("AutoReqProv:"):
        out.append(requires)
with open(path, "w", encoding="utf-8") as fh:
    fh.write("\n".join(out) + "\n")
PY

if [[ "$STAGE_ONLY" == "1" ]]; then
  ok "stage-only: $TOP (spec: $SPEC)"
  exit 0
fi

log "rpmbuild --target $RPM_ARCH"
dh_have rpmbuild || die "Falta rpmbuild. Instálalo con: sudo apt install rpm (Linux Mint/Ubuntu)."
rpmbuild -bb \
  --define "_topdir $TOP" \
  --define "_sourcedir $TOP/SOURCES" \
  --define "_rpmdir $TOP/RPMS" \
  --target "$RPM_ARCH" \
  "$SPEC" >/dev/null

RPM_FILE="$(find "$TOP/RPMS" -type f -name '*.rpm' | head -n1)"
[[ -n "$RPM_FILE" ]] || die "rpmbuild no generó ningún .rpm"
OUT="$DH_DIST_DIR/$(basename -- "$RPM_FILE")"
install -m 0644 "$RPM_FILE" "$OUT"

ok "generado: $OUT ($(du -h "$OUT" | cut -f1))"
log "instalar con: sudo dnf install ./$(basename -- "$OUT")"
