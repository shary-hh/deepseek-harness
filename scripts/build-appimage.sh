#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Construye un AppImage portable (x86_64 / aarch64).
#
# Uso: scripts/build-appimage.sh [opciones]
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
Construye un AppImage portable.

Uso: scripts/build-appimage.sh [opciones]

  --version VERSION     Versión (por defecto: ./VERSION)
  --arch ARCH           x86_64 | aarch64 (por defecto: host)
  --app-dir DIR         Payload a empaquetar (por defecto: ./app)
  --output-dir DIR      Destino del .AppImage (por defecto: ./dist)
  --system-node         Usa el Node del sistema en lugar de empaquetarlo
  --allow-sensitive     No abortar si el payload tiene .env/*.pem/etc.
  --stage-only          Solo preparar el AppDir
  -h, --help            Ayuda

Requiere appimagetool: scripts/bootstrap-tools.sh --appimage
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

dh_banner "AppImage"
dh_need tar gzip
dh_warn_placeholder
dh_prepare_dirs

VERSION="$(dh_version)"
APPDIR="$DH_BUILD_DIR/appimage/${APP_NAME}.AppDir"
OUT="$DH_DIST_DIR/${APP_NAME}-${VERSION}-${DH_ARCH}.AppImage"

rm -rf -- "$APPDIR"
mkdir -p "$APPDIR/usr/bin" \
  "$APPDIR/usr/share/applications" \
  "$APPDIR/usr/share/icons/hicolor/256x256/apps"

log "versión $VERSION · $DH_ARCH · node: $MODE"
dh_stage_payload "$APPDIR/usr/lib/$APP_NAME" "$MODE"
rm -rf -- "$APPDIR/usr/lib/$APP_NAME/share"

ln -s "../lib/$APP_NAME/bin/$APP_BIN" "$APPDIR/usr/bin/$APP_BIN"

install -m 0755 "$REPO_ROOT/packaging/appimage/AppRun" "$APPDIR/AppRun"

sed "s|@VERSION@|$VERSION|g" \
  "$REPO_ROOT/packaging/appimage/$APP_BIN.desktop.in" > "$APPDIR/$APP_BIN.desktop"
chmod 0644 "$APPDIR/$APP_BIN.desktop"
install -m 0644 "$APPDIR/$APP_BIN.desktop" \
  "$APPDIR/usr/share/applications/$APP_BIN.desktop"

install -m 0644 "$REPO_ROOT/assets/$APP_BIN.png" "$APPDIR/$APP_BIN.png"
install -m 0644 "$REPO_ROOT/assets/$APP_BIN.png" \
  "$APPDIR/usr/share/icons/hicolor/256x256/apps/$APP_BIN.png"
install -m 0644 "$REPO_ROOT/LICENSE" "$APPDIR/LICENSE"

if [[ "$STAGE_ONLY" == "1" ]]; then
  ok "stage-only: $APPDIR"
  exit 0
fi

TOOL="$DH_CACHE_DIR/tools/appimagetool-${DH_ARCH}.AppImage"
RUNTIME="$DH_CACHE_DIR/tools/runtime-${DH_ARCH}"
if [[ ! -x "$TOOL" || ! -f "$RUNTIME" ]]; then
  log "faltan herramientas de AppImage; ejecutando bootstrap"
  "$SCRIPT_DIR/bootstrap-tools.sh" --appimage
fi
[[ -x "$TOOL" ]] || die "appimagetool no disponible en $TOOL"

RUNTIME_ARGS=()
if [[ -f "$RUNTIME" ]]; then
  RUNTIME_ARGS=(--runtime-file "$RUNTIME")
else
  warn "runtime de AppImage no está en caché; appimagetool descargará uno sin pin."
fi

log "empaquetando AppImage"
ARCH="$DH_ARCH" APPIMAGE_EXTRACT_AND_RUN=1 \
  "$TOOL" --no-appstream "${RUNTIME_ARGS[@]}" "$APPDIR" "$OUT" >/dev/null

chmod 0755 "$OUT"
ok "generado: $OUT ($(du -h "$OUT" | cut -f1))"
log "ejecutar con: ./$(basename -- "$OUT") --help"
