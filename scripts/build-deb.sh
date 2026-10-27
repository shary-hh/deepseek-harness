#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Construye un paquete .deb para Debian/Ubuntu/Linux Mint.
#
# Uso:
#   scripts/build-deb.sh [opciones]
#
# Opciones:
#   --version VERSION     Versión del paquete (por defecto: ./VERSION)
#   --arch ARCH           amd64 | arm64 | x86_64 | aarch64 (por defecto: host)
#   --app-dir DIR         Payload a empaquetar (por defecto: ./app)
#   --output-dir DIR      Destino del .deb (por defecto: ./dist)
#   --system-node         Depende de nodejs del sistema en lugar de empaquetarlo
#   --allow-sensitive     No abortar si el payload tiene .env/*.pem/etc.
#   --stage-only          Solo preparar el árbol, sin ejecutar dpkg-deb
#   -h, --help            Ayuda
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
Construye un paquete .deb para Debian/Ubuntu/Linux Mint.

Uso: scripts/build-deb.sh [opciones]

  --version VERSION     Versión del paquete (por defecto: ./VERSION)
  --arch ARCH           amd64 | arm64 | x86_64 | aarch64 (por defecto: host)
  --app-dir DIR         Payload a empaquetar (por defecto: ./app)
  --output-dir DIR      Destino del .deb (por defecto: ./dist)
  --system-node         Depende de nodejs del sistema en lugar de empaquetarlo
  --allow-sensitive     No abortar si el payload tiene .env/*.pem/etc.
  --stage-only          Solo preparar el árbol, sin ejecutar dpkg-deb
  -h, --help            Ayuda
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

dh_banner "paquete .deb"
dh_need dpkg-deb tar gzip
dh_warn_placeholder
dh_prepare_dirs

VERSION="$(dh_version)"
DEB_ARCH="$(dh_deb_arch "$DH_ARCH")"
PKGROOT="$DH_BUILD_DIR/deb/${APP_NAME}_${VERSION}_${DEB_ARCH}"
OUT="$DH_DIST_DIR/${APP_NAME}_${VERSION}_${DEB_ARCH}.deb"

log "versión $VERSION · arquitectura $DEB_ARCH · node: $MODE"

rm -rf -- "$PKGROOT"
mkdir -p "$PKGROOT/DEBIAN"

dh_stage_payload "$PKGROOT/opt/$APP_NAME" "$MODE"

# Instalar doc/man en ubicaciones estándar de Debian.
install -d -m 0755 "$PKGROOT/usr/bin" \
  "$PKGROOT/usr/share/man/man1" \
  "$PKGROOT/usr/share/doc/$APP_NAME"

if [[ -f "$PKGROOT/opt/$APP_NAME/share/man/man1/$APP_BIN.1" ]]; then
  gzip -9n -c "$PKGROOT/opt/$APP_NAME/share/man/man1/$APP_BIN.1" \
    > "$PKGROOT/usr/share/man/man1/$APP_BIN.1.gz"
  chmod 0644 "$PKGROOT/usr/share/man/man1/$APP_BIN.1.gz"
fi

if [[ -f "$PKGROOT/opt/$APP_NAME/share/doc/$APP_NAME/LICENSE" ]]; then
  cp -f "$PKGROOT/opt/$APP_NAME/share/doc/$APP_NAME/LICENSE" \
    "$PKGROOT/usr/share/doc/$APP_NAME/LICENSE"
fi
rm -rf -- "$PKGROOT/opt/$APP_NAME/share"

ln -s "/opt/$APP_NAME/bin/$APP_BIN" "$PKGROOT/usr/bin/$APP_BIN"

YEAR="$(date -u +%Y)"
sed -e "s|@APP_NAME@|$APP_NAME|g" \
    -e "s|@HOMEPAGE@|$(dh_homepage)|g" \
    -e "s|@VENDOR@|$APP_VENDOR|g" \
    -e "s|@YEAR@|$YEAR|g" \
    "$REPO_ROOT/packaging/deb/copyright.in" \
  > "$PKGROOT/usr/share/doc/$APP_NAME/copyright"

if [[ "$MODE" == "system" ]]; then
  DEPENDS="nodejs (>= 20), ca-certificates"
else
  DEPENDS="libc6 (>= 2.28), libgcc-s1, libstdc++6"
fi

INSTALLED_SIZE="$(du -sk --apparent-size --exclude=DEBIAN "$PKGROOT" | cut -f1)"
[[ "$INSTALLED_SIZE" =~ ^[0-9]+$ ]] || die "No se pudo calcular Installed-Size"

sed -e "s|@APP_NAME@|$APP_NAME|g" \
    -e "s|@VERSION@|$VERSION|g" \
    -e "s|@ARCH@|$DEB_ARCH|g" \
    -e "s|@MAINTAINER@|$APP_MAINTAINER|g" \
    -e "s|@INSTALLED_SIZE@|$INSTALLED_SIZE|g" \
    -e "s|@DEPENDS@|$DEPENDS|g" \
    -e "s|@SECTION@|$APP_SECTION|g" \
    -e "s|@HOMEPAGE@|$(dh_homepage)|g" \
    -e "s|@SHORT@|$APP_DESC|g" \
    -e "s|@LONG@|$APP_LONG_DESC|g" \
    "$REPO_ROOT/packaging/deb/control.in" > "$PKGROOT/DEBIAN/control"

# Permisos deterministas antes de calcular md5sums.
find "$PKGROOT" -type d -exec chmod 0755 {} +
find "$PKGROOT" -type f -exec chmod 0644 {} +
chmod 0755 "$PKGROOT/opt/$APP_NAME/bin/$APP_BIN"
if [[ -f "$PKGROOT/opt/$APP_NAME/lib/node/bin/node" ]]; then
  chmod 0755 "$PKGROOT/opt/$APP_NAME/lib/node/bin/node"
fi

(
  cd "$PKGROOT"
  find . -type f ! -path './DEBIAN/*' -print0 \
    | LC_ALL=C sort -z \
    | xargs -0 md5sum \
    | sed 's|  \./|  |' \
    > DEBIAN/md5sums
) || die "No se pudo generar DEBIAN/md5sums"
chmod 0644 "$PKGROOT/DEBIAN/md5sums"

if [[ "$STAGE_ONLY" == "1" ]]; then
  ok "stage-only: $PKGROOT"
  exit 0
fi

log "construyendo $OUT"
if dpkg-deb --help 2>/dev/null | grep -q -- '--root-owner-group'; then
  dpkg-deb --root-owner-group --build "$PKGROOT" "$OUT" >/dev/null
else
  dh_need fakeroot
  fakeroot dpkg-deb --build "$PKGROOT" "$OUT" >/dev/null
fi

ok "generado: $OUT ($(du -h "$OUT" | cut -f1))"
log "instalar con: sudo apt install ./$(basename -- "$OUT")"
