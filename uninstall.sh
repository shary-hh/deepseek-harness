#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Desinstalador de deepseek-harness.
#
# Uso: ./uninstall.sh --system | --user [--prefix DIR] [--purge]
# ---------------------------------------------------------------------------
set -Eeuo pipefail
umask 022

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/lib/common.sh
. "$SCRIPT_DIR/scripts/lib/common.sh"

usage() {
  cat <<'EOF'
Desinstala deepseek-harness.

Uso: ./uninstall.sh [opciones]

  --system          Desinstala el paquete del sistema (apt/dpkg)
  --user            Desinstala la copia en ~/.local (sin sudo)
  --prefix DIR      Prefijo usado con --user (por defecto: ~/.local)
  --purge           Elimina también la configuración del paquete (modo sistema)
  --dry-run         Muestra lo que haría
  --yes             No preguntar
  -h, --help        Ayuda

Nota: NO borra tus claves de API ni tu configuración personal en
~/.config/deepseek-harness (bórrala tú si lo deseas).
EOF
}

MODE="system"; PREFIX="$HOME/.local"; PURGE=0; DRY_RUN=0

while (($#)); do
  case "$1" in
    --system)  MODE="system"; shift ;;
    --user)    MODE="user"; shift ;;
    --prefix)  PREFIX="${2:?--prefix requiere un valor}"; shift 2 ;;
    --purge)   PURGE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --yes)     ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)         die "Opción desconocida: $1" ;;
  esac
done

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '+'; printf ' %q' "$@"; printf '\n' >&2
  else
    "$@"
  fi
}

dh_banner "desinstalador"

if [[ "$MODE" == "system" ]]; then
  if ! dpkg-query -W -f='${Status}' "$APP_NAME" 2>/dev/null | grep -q 'install ok installed'; then
    warn "$APP_NAME no está instalado como paquete del sistema."
    exit 0
  fi
  dh_confirm "¿Desinstalar $APP_NAME del sistema?" || die "Cancelado."
  if [[ "$PURGE" == "1" ]]; then
    run dh_sudo env DEBIAN_FRONTEND=noninteractive apt-get purge -y "$APP_NAME"
  else
    run dh_sudo env DEBIAN_FRONTEND=noninteractive apt-get remove -y "$APP_NAME"
  fi
  ok "desinstalado del sistema"
  exit 0
fi

# --- Modo usuario ----------------------------------------------------------
[[ "$PREFIX" == /* ]] || die "--prefix debe ser una ruta absoluta."
[[ "$PREFIX" != "/" ]] || die "Prefijo inválido: /"

TARGET="$PREFIX/opt/$APP_NAME"
LINK="$PREFIX/bin/$APP_BIN"
MAN="$PREFIX/share/man/man1/$APP_BIN.1.gz"

if [[ ! -e "$TARGET" && ! -L "$LINK" ]]; then
  warn "no se encontró una instalación de usuario en $TARGET"
  exit 0
fi

# Seguridad: solo borramos la ruta esperada.
[[ "$(basename -- "$TARGET")" == "$APP_NAME" ]] || die "Ruta inesperada: $TARGET"

dh_confirm "¿Eliminar $TARGET y $LINK?" || die "Cancelado."

run rm -f -- "$LINK" "$MAN"
run rm -rf -- "$TARGET"
run rmdir --ignore-fail-on-non-empty "$PREFIX/opt" "$PREFIX/bin" \
  "$PREFIX/share/man/man1" "$PREFIX/share/man" "$PREFIX/share" 2>/dev/null || true

ok "desinstalado de $PREFIX"
warn "tu configuración personal sigue en ~/.config/$APP_NAME (no se toca)."
