#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Construye el paquete para Windows:
#   * ZIP portable (node.exe + app + lanzador .cmd)  -> siempre
#   * instalador .exe con NSIS                        -> si makensis está
#   * binario único con Node SEA (experimental)       -> con --sea
#
# Uso: scripts/build-exe.sh [opciones]
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
Construye el paquete de Windows (.zip portable y .exe instalable).

Uso: scripts/build-exe.sh [opciones]

  --version VERSION     Versión (por defecto: ./VERSION)
  --arch ARCH           x64 | arm64 (por defecto: x64)
  --app-dir DIR         Payload a empaquetar (por defecto: ./app)
  --output-dir DIR      Destino (por defecto: ./dist)
  --allow-sensitive     No abortar si el payload tiene .env/*.pem/etc.
  --no-installer        No generar el instalador NSIS
  --sea                 Generar además un .exe único con Node SEA (experimental)
  --stage-only          Solo preparar el árbol portable
  -h, --help            Ayuda

Requisitos: bash, tar, curl, python3. Para el instalador: makensis (apt install nsis).
El ZIP portable funciona sin herramientas extra.
EOF
}

VERSION=""; ARCH="x64"; STAGE_ONLY=0; INSTALLER="auto"; SEA=0

while (($#)); do
  case "$1" in
    --version)      VERSION="${2:?--version requiere un valor}"; shift 2 ;;
    --arch)         ARCH="${2:?--arch requiere un valor}"; shift 2 ;;
    --app-dir)      DH_APP_DIR="${2:?--app-dir requiere un valor}"; shift 2 ;;
    --output-dir)   DH_DIST_DIR="${2:?--output-dir requiere un valor}"; shift 2 ;;
    --allow-sensitive) export DH_ALLOW_SENSITIVE=1; shift ;;
    --no-installer) INSTALLER="no"; shift ;;
    --sea)          SEA=1; shift ;;
    --stage-only)   STAGE_ONLY=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *)              die "Opción desconocida: $1" ;;
  esac
done

[[ -n "$VERSION" ]] && export DH_VERSION="$VERSION"
DH_ARCH="$(dh_norm_arch "$ARCH")"
export DH_ARCH

dh_banner "paquete Windows"
dh_need tar curl python3
dh_warn_placeholder
dh_prepare_dirs

VERSION="$(dh_version)"
WINARCH="$(dh_win_arch "$DH_ARCH")"
WINROOT="$DH_BUILD_DIR/windows"
NAME="${APP_NAME}-${VERSION}-win-${WINARCH}"
STAGED="$WINROOT/$NAME"
OUTZIP="$DH_DIST_DIR/${NAME}.zip"
OUTEXE="$DH_DIST_DIR/${NAME}-setup.exe"

rm -rf -- "$STAGED" "$OUTZIP" "$OUTEXE"
mkdir -p "$STAGED/app"

[[ "${DH_ALLOW_SENSITIVE:-0}" == "1" ]] || dh_assert_no_sensitive "$DH_APP_DIR"

log "versión $VERSION · win-$WINARCH"

# Copia el payload sin .git ni artefactos de desarrollo.
tar -C "$DH_APP_DIR" \
  --exclude='./.git' --exclude='./.github' --exclude='./.gitignore' \
  --exclude='./node_modules/.cache' \
  -cf - . | tar -C "$STAGED/app" -xf -

ENTRY="$(dh_resolve_entrypoint "$STAGED/app")"
log "entrypoint: $ENTRY"

dh_node_install_windows "$DH_ARCH" "$STAGED"

sed "s|__ENTRY__|$ENTRY|g" \
  "$REPO_ROOT/packaging/windows/$APP_BIN.cmd.in" > "$STAGED/$APP_BIN.cmd"
# CRLF para cmd.exe
sed -i 's/$/\r/' "$STAGED/$APP_BIN.cmd"

install -m 0644 "$REPO_ROOT/LICENSE" "$STAGED/LICENSE"
sed -e "s|@VERSION@|$VERSION|g" \
    -e "s|@ARCH@|$WINARCH|g" \
    -e "s|@NODE_VERSION@|$DH_NODE_VERSION|g" \
    -e "s|@HOMEPAGE@|$(dh_homepage)|g" \
    "$REPO_ROOT/packaging/windows/README.txt.in" > "$STAGED/README.txt"

if [[ "$STAGE_ONLY" == "1" ]]; then
  ok "stage-only: $STAGED"
  exit 0
fi

# --- ZIP portable ----------------------------------------------------------
if dh_have zip; then
  ( cd "$WINROOT" && zip -qr -9 "$OUTZIP" "$NAME" )
else
  python3 - "$STAGED" "$OUTZIP" <<'PY'
import os, sys, zipfile
src, out = sys.argv[1], sys.argv[2]
base = os.path.basename(src)
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, 9) as zf:
    for root, _dirs, files in os.walk(src):
        for name in files:
            full = os.path.join(root, name)
            rel = os.path.join(base, os.path.relpath(full, src))
            zf.write(full, rel)
PY
fi
ok "generado: $OUTZIP ($(du -h "$OUTZIP" | cut -f1))"

# --- Instalador NSIS -------------------------------------------------------
if [[ "$INSTALLER" != "no" ]]; then
  if dh_have makensis; then
    APP_VERSION4="$(printf '%s' "$VERSION" | awk -F'[^0-9]+' '{printf "%s.%s.%s.%s", $1, ($2==""?0:$2), ($3==""?0:$3), ($4==""?0:$4)}')"
    log "generando instalador NSIS"
    makensis -V2 \
      -DAPP_NAME="$APP_NAME" \
      -DAPP_VERSION="$VERSION" \
      -DAPP_VERSION4="$APP_VERSION4" \
      -DAPP_PUBLISHER="$APP_VENDOR" \
      -DAPP_URL="$(dh_homepage)" \
      -DSOURCE_DIR="$STAGED" \
      -DOUT_FILE="$OUTEXE" \
      "$REPO_ROOT/packaging/windows/installer.nsi" >/dev/null
    ok "generado: $OUTEXE ($(du -h "$OUTEXE" | cut -f1))"
  else
    warn "makensis no está instalado; se omite el instalador .exe"
    warn "Instálalo con: scripts/bootstrap-tools.sh --exe"
  fi
fi

# --- Node SEA (experimental) ----------------------------------------------
if [[ "$SEA" == "1" ]]; then
  dh_need node npx
  SEA_DIR="$WINROOT/sea"
  rm -rf -- "$SEA_DIR"; mkdir -p "$SEA_DIR"

  log "bundle con esbuild (Node SEA)"
  npx --yes esbuild@0.24.2 "$STAGED/app/$ENTRY" \
    --bundle --platform=node --format=cjs --target=node20 \
    --outfile="$SEA_DIR/bundle.js" >/dev/null

  cat > "$SEA_DIR/sea-config.json" <<'JSON'
{
  "main": "bundle.js",
  "output": "sea-prep.blob",
  "disableExperimentalSEAWarning": true,
  "useSnapshot": false,
  "useCodeCache": false
}
JSON

  ( cd "$SEA_DIR" && node --experimental-sea-config sea-config.json ) >/dev/null

  cp -f "$STAGED/node.exe" "$SEA_DIR/$APP_NAME.exe"
  npx --yes postject@1.0.0-alpha.6 "$SEA_DIR/$APP_NAME.exe" NODE_SEA_BLOB \
    "$SEA_DIR/sea-prep.blob" \
    --sentinel-fuse NODE_SEA_FUSE_fce680ab2cc467b6e072b8b5df1996b2 >/dev/null

  install -m 0755 "$SEA_DIR/$APP_NAME.exe" "$DH_DIST_DIR/${APP_NAME}-${VERSION}-win-${WINARCH}.exe"
  ok "generado: $DH_DIST_DIR/${APP_NAME}-${VERSION}-win-${WINARCH}.exe (SEA, experimental)"
fi

log "nota: el ZIP portable no requiere instalación ni privilegios de administrador"
