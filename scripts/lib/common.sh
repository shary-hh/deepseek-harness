#!/usr/bin/env bash
# shellcheck shell=bash
# ---------------------------------------------------------------------------
# Utilidades compartidas por todos los scripts de empaquetado e instalación.
#
# Reglas de la casa:
#   * Nada de secretos en argumentos, logs ni archivos del repo.
#   * Toda descarga HTTPS se verifica con SHA256 (salvo escape explícito).
#   * Los scripts se pueden ejecutar desde cualquier directorio.
# ---------------------------------------------------------------------------

[[ -n "${DH_COMMON_LOADED:-}" ]] && return 0
DH_COMMON_LOADED=1

set -Eeuo pipefail

DH_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$DH_LIB_DIR/../.." && pwd -P)"

# --- Metadatos -------------------------------------------------------------
# shellcheck source=../../packaging/metadata.env
if [[ -r "$REPO_ROOT/packaging/metadata.env" ]]; then
  . "$REPO_ROOT/packaging/metadata.env"
fi

APP_NAME="${APP_NAME:-deepseek-harness}"
APP_BIN="${APP_BIN:-$APP_NAME}"
APP_VENDOR="${APP_VENDOR:-DeepSeek Harness Contributors}"
APP_MAINTAINER="${APP_MAINTAINER:-DeepSeek Harness Maintainers <maintainers@users.noreply.github.com>}"
APP_HOMEPAGE="${APP_HOMEPAGE:-https://github.com/OWNER/deepseek-harness}"
APP_LICENSE="${APP_LICENSE:-GPL-3.0-or-later}"
APP_SECTION="${APP_SECTION:-utils}"
APP_CATEGORY="${APP_CATEGORY:-Development}"
APP_DESC="${APP_DESC:-CLI harness for DeepSeek models}"
APP_LONG_DESC="${APP_LONG_DESC:-$APP_DESC}"
APP_KEYWORDS="${APP_KEYWORDS:-deepseek;cli;ai;harness}"
DH_NODE_VERSION="${DH_NODE_VERSION:-24.22.1}"
DH_REPO_SLUG="${DH_REPO_SLUG:-}"

# --- Rutas -----------------------------------------------------------------
DH_DIST_DIR="${DH_DIST_DIR:-$REPO_ROOT/dist}"
DH_BUILD_DIR="${DH_BUILD_DIR:-$REPO_ROOT/build}"
DH_CACHE_DIR="${DH_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/deepseek-harness}"
DH_APP_DIR="${DH_APP_DIR:-$REPO_ROOT/app}"

# --- Salida ----------------------------------------------------------------
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
  C_RESET=''; C_BOLD=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''
fi

log()   { printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*" >&2; }
ok()    { printf '%s ok %s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
warn()  { printf '%saviso:%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()   { printf '%serror:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

dh_banner() {
  log "${C_BOLD}${APP_NAME}${C_RESET} · $*"
}

# --- Utilidades básicas ----------------------------------------------------
dh_have() { command -v "$1" >/dev/null 2>&1; }

dh_need() {
  local missing=()
  local c
  for c in "$@"; do
    dh_have "$c" || missing+=("$c")
  done
  ((${#missing[@]} == 0)) || die "Faltan dependencias: ${missing[*]}"
}

# Ejecuta como root solo cuando hace falta.
dh_sudo() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
    return
  fi
  dh_have sudo || die "Se requieren privilegios de root y 'sudo' no está instalado."
  sudo -- "$@"
}

# Pregunta sí/no. Con ASSUME_YES=1 o --yes devuelve 0 sin preguntar.
# Sin TTY devuelve 1 (falla cerrado) para no romper automatizaciones.
dh_confirm() {
  local prompt="$1" answer=""
  if [[ "${ASSUME_YES:-0}" == "1" ]]; then
    log "$prompt: sí (--yes)"
    return 0
  fi
  if [[ ! -t 0 ]]; then
    warn "Sin TTY para '${prompt}'; se asume NO."
    return 1
  fi
  read -r -p "$prompt [s/N] " answer || true
  case "$answer" in
    s|S|y|Y|si|SI|Si|sí|Sí|SÍ|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

# Oculta posibles secretos en mensajes de error/log.
dh_redact() {
  sed -E \
    -e 's/(ghp_|github_pat_|sk-|xox[baprs]-)[A-Za-z0-9_-]+/\1***REDACTED***/g' \
    -e 's/(AKIA)[0-9A-Z]{16}/\1***REDACTED***/g' \
    -e 's/(Bearer )[A-Za-z0-9._-]+/\1***REDACTED***/g'
}

dh_require_linux() {
  [[ "$(uname -s)" == "Linux" ]] || die "Este script es solo para Linux (detectado: $(uname -s))."
}

# --- Versión / repositorio -------------------------------------------------
dh_version() {
  if [[ -n "${DH_VERSION:-}" ]]; then
    printf '%s' "$DH_VERSION"
    return
  fi
  local v=""
  [[ -r "$REPO_ROOT/VERSION" ]] && v="$(tr -d '[:space:]' < "$REPO_ROOT/VERSION")"
  [[ -n "$v" ]] || die "No se pudo determinar la versión: VERSION está vacío o falta."
  printf '%s' "$v"
}

# Deduce owner/repo desde el remoto origin (nunca lee credenciales).
dh_repo_slug() {
  if [[ -n "$DH_REPO_SLUG" ]]; then
    printf '%s' "$DH_REPO_SLUG"
    return
  fi
  local url=""
  url="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
  case "$url" in
    git@github.com:*)       url="${url#git@github.com:}" ;;
    ssh://git@github.com/*) url="${url#ssh://git@github.com/}" ;;
    https://github.com/*)   url="${url#https://github.com/}" ;;
    *)                      url="" ;;
  esac
  url="${url%.git}"
  printf '%s' "$url"
}

dh_homepage() {
  local slug
  slug="$(dh_repo_slug)"
  if [[ -n "$slug" && "$APP_HOMEPAGE" == *"/OWNER/"* ]]; then
    printf 'https://github.com/%s' "$slug"
  else
    printf '%s' "$APP_HOMEPAGE"
  fi
}

dh_warn_placeholder() {
  if [[ "$(dh_homepage)" == *OWNER* ]]; then
    warn "APP_HOMEPAGE sigue con 'OWNER'. Edita packaging/metadata.env o configura 'origin'."
  fi
}

# --- Arquitecturas ---------------------------------------------------------
dh_host_arch() { uname -m; }

dh_norm_arch() {
  local arch="${1:-$(dh_host_arch)}"
  case "$arch" in
    x86_64|amd64|x64)  printf 'x86_64' ;;
    aarch64|arm64)     printf 'aarch64' ;;
    *) die "Arquitectura no soportada: $arch (usa x86_64/amd64 o aarch64/arm64)." ;;
  esac
}

dh_deb_arch() {
  case "$(dh_norm_arch "${1:-}")" in
    x86_64)  printf 'amd64' ;;
    aarch64) printf 'arm64' ;;
  esac
}

dh_win_arch() {
  case "$(dh_norm_arch "${1:-}")" in
    x86_64)  printf 'x64' ;;
    aarch64) printf 'arm64' ;;
  esac
}

# --- Descargas verificadas -------------------------------------------------
# Uso: dh_fetch URL DESTINO [SHA256]
# Si SHA256 está vacío solo se permite con DH_ALLOW_UNVERIFIED=1.
dh_fetch() {
  local url="$1" dest="$2" want="${3:-}"
  local tmp
  mkdir -p "$(dirname -- "$dest")"

  if [[ -f "$dest" ]]; then
    if [[ -n "$want" ]] && dh_sha256_ok "$dest" "$want"; then
      log "cache: $(basename -- "$dest")"
      return 0
    fi
    rm -f -- "$dest"
  fi

  if [[ -z "$want" && "${DH_ALLOW_UNVERIFIED:-0}" != "1" ]]; then
    die "No hay SHA256 fijado para $url. Define el hash o usa DH_ALLOW_UNVERIFIED=1 (no recomendado)."
  fi

  tmp="$(mktemp "$dest.part.XXXXXX")"
  log "descargando $(basename -- "$dest")"
  if ! curl -fL --retry 3 --retry-delay 2 --proto '=https' --tlsv1.2 \
        --connect-timeout 20 -o "$tmp" "$url" 2>/dev/null; then
    rm -f -- "$tmp"
    die "Falló la descarga: $url"
  fi

  if [[ -n "$want" ]]; then
    if ! dh_sha256_ok "$tmp" "$want"; then
      local got
      got="$(sha256sum "$tmp" | awk '{print $1}')"
      rm -f -- "$tmp"
      die "SHA256 no coincide para $(basename -- "$dest")
       esperado: $want
       obtenido: $got"
    fi
  else
    warn "Descarga SIN verificar: $url"
    warn "SHA256 obtenido: $(sha256sum "$tmp" | awk '{print $1}')"
  fi

  chmod 0644 "$tmp"
  mv -f -- "$tmp" "$dest"
}

dh_sha256_ok() {
  local file="$1" want="$2" got
  [[ -r "$file" ]] || return 1
  got="$(sha256sum "$file" | awk '{print $1}')"
  [[ "$got" == "$want" ]]
}

dh_verify_sha256() {
  local file="$1" want="$2" label="${3:-$(basename -- "$1")}"
  [[ -r "$file" ]] || die "No existe el archivo a verificar: $file"
  dh_sha256_ok "$file" "$want" || die "SHA256 inválido para $label"
  ok "SHA256 verificado: $label"
}

# --- Directorios de trabajo -------------------------------------------------
dh_tmpdir() {
  local parent="${TMPDIR:-/tmp}"
  [[ -d "$parent" ]] || parent=/tmp
  mktemp -d "$parent/dh.XXXXXX"
}

dh_prepare_dirs() {
  mkdir -p "$DH_BUILD_DIR" "$DH_DIST_DIR" "$DH_CACHE_DIR"
  chmod 0755 "$DH_BUILD_DIR" "$DH_DIST_DIR" "$DH_CACHE_DIR" 2>/dev/null || true
}

# --- Checksums de release ---------------------------------------------------
# Genera dist/SHA256SUMS de forma determinista.
dh_write_checksums() {
  local dir="${1:-$DH_DIST_DIR}"
  (
    cd "$dir" || exit 1
    find . -maxdepth 1 -type f \
      ! -name 'SHA256SUMS' ! -name 'SHA256SUMS.asc' \
      -printf '%f\0' \
      | LC_ALL=C sort -z \
      | xargs -0 -r sha256sum > SHA256SUMS
  ) || die "No se pudieron generar los checksums en $dir"
  ok "checksums: $dir/SHA256SUMS"
}
