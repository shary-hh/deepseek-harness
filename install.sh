#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Instalador de deepseek-harness para Linux Mint 22.x / Debian / Ubuntu.
#
#   * Instala el .deb del release (verificado con SHA256 y, opcionalmente, GPG).
#   * O compila e instala desde el código local (--from-source).
#   * Modo sistema (/opt + /usr/bin, requiere sudo) o usuario (~/.local, sin sudo).
#
# No pide, guarda ni imprime claves de API. No escribe secretos en disco.
# ---------------------------------------------------------------------------
set -Eeuo pipefail
umask 022

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/lib/common.sh
. "$SCRIPT_DIR/scripts/lib/common.sh"

usage() {
  cat <<'EOF'
Instala deepseek-harness en Linux Mint / Debian / Ubuntu.

Uso: ./install.sh [opciones]

Modo (por defecto: --system)
  --system              Instala en /opt + /usr/bin (requiere sudo)
  --user                Instala en ~/.local (sin sudo)

Origen
  --version VERSION     Versión a instalar (por defecto: ./VERSION o último release)
  --from-source         Compila el .deb desde ./app y lo instala
  --deb ARCHIVO.deb     Instala un .deb local ya descargado
  --source-dir DIR      Payload fuente para --from-source (por defecto: ./app)

Verificación
  --sha256 HASH         SHA256 esperado del .deb (obtenido fuera de banda)
  --gpg-key ARCHIVO     Clave pública para verificar SHA256SUMS.asc
  --no-verify           Omite la verificación (NO recomendado)

Otros
  --prefix DIR          Prefijo para --user (por defecto: ~/.local)
  --dry-run             Muestra lo que haría, sin cambiar nada
  --yes                 No preguntar
  --uninstall           Desinstala (combínalo con --system/--user)
  --no-apt              No instalar dependencias con apt
  -h, --help            Ayuda

Ejemplos:
  ./install.sh --user
  ./install.sh --system --version 0.1.0 --sha256 <hash>
  ./install.sh --from-source --user --yes
EOF
}

MODE="system"; VERSION=""; FROM_SOURCE=0; DEB_FILE=""; PREFIX="$HOME/.local"
EXPECTED_SHA=""; GPG_KEY=""; VERIFY=1; DRY_RUN=0; UNINSTALL=0; NO_APT=0; SOURCE_DIR=""

while (($#)); do
  case "$1" in
    --system)      MODE="system"; shift ;;
    --user)        MODE="user"; shift ;;
    --version)     VERSION="${2:?--version requiere un valor}"; shift 2 ;;
    --from-source) FROM_SOURCE=1; shift ;;
    --deb)         DEB_FILE="${2:?--deb requiere un valor}"; shift 2 ;;
    --source-dir)  SOURCE_DIR="${2:?--source-dir requiere un valor}"; shift 2 ;;
    --prefix)      PREFIX="${2:?--prefix requiere un valor}"; shift 2 ;;
    --sha256)      EXPECTED_SHA="${2:?--sha256 requiere un valor}"; shift 2 ;;
    --gpg-key)     GPG_KEY="${2:?--gpg-key requiere un valor}"; shift 2 ;;
    --no-verify)   VERIFY=0; shift ;;
    --dry-run)     DRY_RUN=1; shift ;;
    --yes)         ASSUME_YES=1; shift ;;
    --uninstall)   UNINSTALL=1; shift ;;
    --no-apt)      NO_APT=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             die "Opción desconocida: $1 (usa --help)" ;;
  esac
done

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '+'; printf ' %q' "$@"; printf '\n' >&2
  else
    "$@"
  fi
}

TMPDIR_INSTALL=""
cleanup() { [[ -n "$TMPDIR_INSTALL" ]] && rm -rf -- "$TMPDIR_INSTALL"; }
trap cleanup EXIT

dh_banner "instalador"

# --- Entorno ---------------------------------------------------------------
dh_require_linux

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    linuxmint|ubuntu|debian|pop|elementary|zorin)
      log "sistema: ${PRETTY_NAME:-$ID}" ;;
    *)
      if [[ "${ID_LIKE:-}" == *debian* || "${ID_LIKE:-}" == *ubuntu* ]]; then
        warn "distribución no probada (${PRETTY_NAME:-$ID}); continúo por ser derivada de Debian."
      else
        die "Este instalador es para Debian/Ubuntu/Mint. En Fedora usa el .rpm."
      fi ;;
  esac
  if [[ "${ID:-}" == "linuxmint" && "${VERSION_ID:-}" != 22* ]]; then
    warn "probado en Linux Mint 22.x; detectado ${VERSION_ID:-desconocido}."
  fi
fi

if [[ "$MODE" == "user" && "${EUID:-$(id -u)}" -eq 0 && "$DRY_RUN" != "1" ]]; then
  warn "estás ejecutando --user como root; se instalará en $PREFIX"
fi

if [[ "$UNINSTALL" == "1" ]]; then
  uninstall_args=(--"$MODE")
  [[ "${ASSUME_YES:-0}" == "1" ]] && uninstall_args+=(--yes)
  [[ "$DRY_RUN" == "1" ]] && uninstall_args+=(--dry-run)
  [[ "$MODE" == "user" ]] && uninstall_args+=(--prefix "$PREFIX")
  exec "$SCRIPT_DIR/uninstall.sh" "${uninstall_args[@]}"
fi

# Instala dependencias básicas con apt si faltan y el usuario acepta.
ensure_deps() {
  local -a need=() pkgs=()
  local c
  for c in sha256sum tar curl gpg dpkg-deb; do
    dh_have "$c" || need+=("$c")
  done
  ((${#need[@]} == 0)) && return 0
  if [[ "$NO_APT" == "1" || "$DRY_RUN" == "1" ]]; then
    return 0
  fi
  dh_have apt-get || return 0
  for c in "${need[@]}"; do
    case "$c" in
      sha256sum) pkgs+=(coreutils) ;;
      tar)       pkgs+=(tar) ;;
      curl)      pkgs+=(curl) ;;
      gpg)       pkgs+=(gnupg) ;;
      dpkg-deb)  pkgs+=(dpkg) ;;
    esac
  done
  ((${#pkgs[@]} == 0)) && return 0
  dh_confirm "¿Instalar dependencias con apt: ${pkgs[*]}?" || return 0
  dh_sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${pkgs[@]}"
}

ensure_deps

dh_need sha256sum tar
if [[ "$DRY_RUN" != "1" ]]; then dh_need dpkg-deb; fi
if [[ "$VERIFY" == "1" || ( -z "$DEB_FILE" && "$FROM_SOURCE" != "1" ) ]]; then
  dh_need curl
fi
if [[ -n "$GPG_KEY" ]]; then dh_need gpg; fi
# --- Utilidades ------------------------------------------------------------
DEB_ARCH="$(dh_deb_arch)"

latest_version() {
  local slug="$1" tag=""
  slug="${slug:-$(dh_repo_slug)}"
  [[ -n "$slug" ]] || return 1
  tag="$(curl -fsSL --proto '=https' --tlsv1.2 \
    "https://api.github.com/repos/$slug/releases/latest" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])' 2>/dev/null || true)"
  tag="${tag#v}"
  printf '%s' "$tag"
}

resolve_version() {
  if [[ -n "$VERSION" ]]; then
    printf '%s' "$VERSION"
    return
  fi
  if [[ -r "$REPO_ROOT/VERSION" && "$FROM_SOURCE" == "1" ]]; then
    dh_version
    return
  fi
  local v
  v="$(latest_version "$(dh_repo_slug)")" || true
  if [[ -z "$v" ]]; then
    if [[ -r "$REPO_ROOT/VERSION" ]]; then
      dh_version
    else
      die "No se pudo determinar la versión. Usa --version X.Y.Z."
    fi
  else
    printf '%s' "$v"
  fi
}

verify_deb() {
  local deb="$1" sums="$2"
  [[ "$VERIFY" == "1" ]] || { warn "verificación de checksum OMITIDA (--no-verify)"; return 0; }

  if [[ -n "$EXPECTED_SHA" ]]; then
    dh_verify_sha256 "$deb" "$EXPECTED_SHA" "$(basename -- "$deb")"
    return 0
  fi

  [[ -f "$sums" ]] || die "No hay SHA256SUMS para verificar. Usa --sha256 o --no-verify."

  if [[ -n "$GPG_KEY" ]]; then
    local tmpgpg="$TMPDIR_INSTALL/gnupg"
    mkdir -p "$tmpgpg"; chmod 0700 "$tmpgpg"
    GNUPGHOME="$tmpgpg" gpg --batch --quiet --import "$GPG_KEY" \
      || die "No se pudo importar la clave GPG."
    GNUPGHOME="$tmpgpg" gpg --batch --quiet --verify "$sums.asc" "$sums" \
      || die "Firma GPG INVÁLIDA para SHA256SUMS."
    ok "firma GPG de SHA256SUMS verificada"
  else
    warn "SHA256SUMS no está firmado (usa --gpg-key para autenticidad real)."
  fi

  local want got
  want="$(awk -v f="$(basename -- "$deb")" '$2 == f { print $1; exit }' "$sums")"
  [[ -n "$want" ]] || die "$(basename -- "$deb") no aparece en SHA256SUMS."
  got="$(sha256sum "$deb" | awk '{print $1}')"
  [[ "$want" == "$got" ]] || die "SHA256 no coincide.
       esperado: $want
       obtenido: $got"
  ok "SHA256 verificado"
}

# --- Verificación de versión instalada -------------------------------------
installed_version_deb() {
  dpkg-query -W -f='${Version}' "$APP_NAME" 2>/dev/null || true
}

# --- Flujo: desde fuente ---------------------------------------------------
build_from_source() {
  local app_dir="${SOURCE_DIR:-$REPO_ROOT/app}" out
  [[ -d "$app_dir" ]] || die "No existe el payload: $app_dir"
  log "compilando .deb desde $app_dir"
  run "$SCRIPT_DIR/scripts/build-deb.sh" --app-dir "$app_dir" --output-dir "$TMPDIR_INSTALL" --arch "$DEB_ARCH"
  out="$(find "$TMPDIR_INSTALL" -maxdepth 1 -name '*.deb' -type f | head -n1)"
  [[ -n "$out" ]] || die "build-deb.sh no generó ningún .deb"
  printf '%s' "$out"
}

# --- Instalación -----------------------------------------------------------
install_system_deb() {
  local deb="$1" ver
  ver="$(dpkg-deb -f "$deb" Version 2>/dev/null || true)"
  if [[ -n "$ver" && "$(installed_version_deb)" == "$ver" ]]; then
    ok "$APP_NAME $ver ya está instalado"
    return 0
  fi
  dh_confirm "¿Instalar $APP_NAME $ver en el sistema (sudo)?" || die "Cancelado."
  if dh_have apt-get; then
    run dh_sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "$deb"
  else
    run dh_sudo dpkg -i "$deb"
    run dh_sudo apt-get -f install -y
  fi
  ok "instalado: $(command -v "$APP_BIN" 2>/dev/null || echo "/usr/bin/$APP_BIN")"
}

install_user_deb() {
  local deb="$1" ver tmp
  ver="$(dpkg-deb -f "$deb" Version 2>/dev/null || true)"
  local target="$PREFIX/opt/$APP_NAME"
  if [[ -x "$target/bin/$APP_BIN" && -f "$target/.version" && "$(cat "$target/.version")" == "$ver" ]]; then
    ok "$APP_NAME $ver ya está instalado en $target"
    return 0
  fi

  tmp="$TMPDIR_INSTALL/extract"
  rm -rf -- "$tmp"; mkdir -p "$tmp"
  log "extrayendo $deb"
  dpkg-deb -x "$deb" "$tmp"

  run install -d -m 0755 "$PREFIX/opt" "$PREFIX/bin" "$PREFIX/share/man/man1"
  run rm -rf -- "$target"
  run cp -a "$tmp/opt/$APP_NAME" "$target"
  printf '%s\n' "$ver" > "$target/.version"
  chmod 0644 "$target/.version"

  if [[ -f "$tmp/usr/share/man/man1/$APP_BIN.1.gz" ]]; then
    run install -m 0644 "$tmp/usr/share/man/man1/$APP_BIN.1.gz" \
      "$PREFIX/share/man/man1/$APP_BIN.1.gz"
  fi
  run ln -sfn "$target/bin/$APP_BIN" "$PREFIX/bin/$APP_BIN"

  ok "instalado: $PREFIX/bin/$APP_BIN"
  case ":$PATH:" in
    *":$PREFIX/bin:"*) ;;
    *) warn "añade a tu PATH: export PATH=\"$PREFIX/bin:\$PATH\"" ;;
  esac
}

# --- Main ------------------------------------------------------------------
dh_prepare_dirs
TMPDIR_INSTALL="$(mktemp -d "${TMPDIR:-/tmp}/dh-install.XXXXXX")"
chmod 0700 "$TMPDIR_INSTALL"

DEB=""
if [[ -n "$DEB_FILE" ]]; then
  [[ -f "$DEB_FILE" ]] || die "No existe el .deb: $DEB_FILE"
  DEB="$(cd -- "$(dirname -- "$DEB_FILE")" && pwd -P)/$(basename -- "$DEB_FILE")"
  VERSION="$(dpkg-deb -f "$DEB" Version 2>/dev/null || echo "$(dh_version)")"
  log "usando .deb local: $DEB (versión $VERSION)"
  if [[ "$VERIFY" == "0" ]]; then
    warn "instalando un .deb local sin verificación de checksum."
  fi
elif [[ "$FROM_SOURCE" == "1" ]]; then
  if [[ "$DRY_RUN" == "1" ]]; then
    log "dry-run: compilaría el .deb desde ${SOURCE_DIR:-$REPO_ROOT/app}"
    exit 0
  fi
  DEB="$(build_from_source)"
  VERSION="$(dpkg-deb -f "$DEB" Version 2>/dev/null || echo "$(dh_version)")"
else
  VERSION="$(resolve_version)"
  [[ -n "$VERSION" ]] || die "Versión vacía."
  SLUG="$(dh_repo_slug)"
  [[ -n "$SLUG" ]] || die "No se pudo deducir el repositorio. Define DH_REPO_SLUG=owner/repo."
  BASE="https://github.com/$SLUG/releases/download/v$VERSION"
  DEB="$TMPDIR_INSTALL/${APP_NAME}_${VERSION}_${DEB_ARCH}.deb"
  SUMS="$TMPDIR_INSTALL/SHA256SUMS"

  if [[ "$DRY_RUN" == "1" ]]; then
    log "dry-run: descargaría $BASE/${APP_NAME}_${VERSION}_${DEB_ARCH}.deb"
    log "dry-run: instalaría en $([[ "$MODE" == system ]] && echo /opt || echo "$PREFIX/opt")/$APP_NAME"
    exit 0
  fi

  log "descargando $APP_NAME $VERSION ($DEB_ARCH) desde $SLUG"
  curl -fL --retry 3 --proto '=https' --tlsv1.2 -o "$DEB" \
    "$BASE/${APP_NAME}_${VERSION}_${DEB_ARCH}.deb" \
    || die "No se pudo descargar el .deb (¿existe el release v$VERSION?)."
  if [[ "$VERIFY" == "1" ]]; then
    curl -fsSL --proto '=https' --tlsv1.2 -o "$SUMS" "$BASE/SHA256SUMS" \
      || die "No se pudo descargar SHA256SUMS."
    if [[ -n "$GPG_KEY" ]]; then
      curl -fsSL --proto '=https' --tlsv1.2 -o "$SUMS.asc" "$BASE/SHA256SUMS.asc" \
        || die "No se pudo descargar SHA256SUMS.asc."
    fi
    verify_deb "$DEB" "$SUMS"
  fi
fi

if [[ "$DRY_RUN" == "1" ]]; then
  if [[ "$MODE" == "system" ]]; then
    log "dry-run: instalaría $DEB con apt/dpkg en el sistema"
  else
    log "dry-run: instalaría $DEB en $PREFIX/opt/$APP_NAME"
  fi
  exit 0
fi

if [[ "$MODE" == "system" ]]; then
  install_system_deb "$DEB"
else
  install_user_deb "$DEB"
fi

log "comprobación rápida"
if [[ "$MODE" == "user" ]]; then
  "$PREFIX/bin/$APP_BIN" --version >/dev/null 2>&1 \
    || warn "el binario no respondió a --version (¿el payload define --version?)."
else
  "$APP_BIN" --version >/dev/null 2>&1 \
    || warn "el binario no respondió a --version (¿el payload define --version?)."
fi

cat >&2 <<EOF

${C_GREEN}Listo.${C_RESET} deepseek-harness $VERSION instalado en modo $MODE.

Siguientes pasos:
  * Configura tu clave SOLO en tu entorno (nunca en el repo):
      export DEEPSEEK_API_KEY="..."   # o usa tu gestor de secretos
  * Ayuda:  $APP_BIN --help
  * Desinstalar:  ./uninstall.sh --$MODE
EOF
