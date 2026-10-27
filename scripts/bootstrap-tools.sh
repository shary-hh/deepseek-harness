#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Instala/descarga las herramientas de empaquetado que no vienen en Linux Mint.
#
# Uso: scripts/bootstrap-tools.sh [--appimage] [--rpm] [--exe] [--all]
#
# Nada se instala sin confirmación (salvo ASSUME_YES=1 / --yes).
# Todo binario descargado se verifica con checksums/tools.sha256.
# ---------------------------------------------------------------------------
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<'EOF'
Prepara las herramientas de empaquetado.

Uso: scripts/bootstrap-tools.sh [opciones]

  --appimage   Descarga appimagetool verificado en la caché local
  --rpm        Instala rpm/rpmbuild con apt (Linux Mint/Ubuntu)
  --exe        Instala nsis y zip con apt (para el instalador .exe)
  --all        Todo lo anterior
  --yes        No preguntar (para CI)
  -h, --help   Ayuda

Variables:
  DH_CACHE_DIR       Caché de herramientas (por defecto ~/.cache/deepseek-harness)
  DH_ALLOW_UNVERIFIED=1  Permite descargar sin checksum (no recomendado)
EOF
}

do_appimage=0 do_rpm=0 do_exe=0

while (($#)); do
  case "$1" in
    --appimage) do_appimage=1; shift ;;
    --rpm)      do_rpm=1; shift ;;
    --exe)      do_exe=1; shift ;;
    --all)      do_appimage=1; do_rpm=1; do_exe=1; shift ;;
    --yes)      export ASSUME_YES=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *)          die "Opción desconocida: $1" ;;
  esac
done

((do_appimage + do_rpm + do_exe > 0)) || { usage; exit 1; }

dh_prepare_dirs

install_apt() {
  local -a pkgs=("$@")
  dh_have apt-get || die "apt-get no está disponible; instala manualmente: ${pkgs[*]}"
  dh_confirm "¿Instalar con apt: ${pkgs[*]}?" || die "Instalación cancelada."
  dh_sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${pkgs[@]}"
}

tool_hash() {
  local name="$1"
  awk -v f="$name" '$2 == f { print $1; exit }' "$REPO_ROOT/checksums/tools.sha256"
}

setup_appimage() {
  local arch asset dest sha runtime runtime_dest runtime_sha
  arch="$(dh_norm_arch)"
  asset="appimagetool-${arch}.AppImage"
  dest="$DH_CACHE_DIR/tools/$asset"
  sha="$(tool_hash "$asset")"

  if [[ -x "$dest" ]]; then
    if [[ -n "$sha" ]] && dh_sha256_ok "$dest" "$sha"; then
      ok "appimagetool ya está en caché"
    else
      warn "appimagetool en caché no coincide con el checksum; se vuelve a descargar"
      rm -f -- "$dest"
    fi
  fi

  if [[ ! -x "$dest" ]]; then
    if [[ -z "$sha" && "${DH_ALLOW_UNVERIFIED:-0}" != "1" ]]; then
      die "No hay checksum para $asset en checksums/tools.sha256.
       Añádelo tras verificar el binario, o usa DH_ALLOW_UNVERIFIED=1."
    fi
    dh_fetch "https://github.com/AppImage/appimagetool/releases/download/continuous/$asset" "$dest" "$sha"
    chmod 0755 "$dest"
    ok "appimagetool: $dest"
  fi

  # Runtime type2 fijado: evita que appimagetool descargue uno sin verificar.
  runtime="runtime-${arch}"
  runtime_dest="$DH_CACHE_DIR/tools/$runtime"
  runtime_sha="$(tool_hash "$runtime")"
  if [[ -f "$runtime_dest" && -n "$runtime_sha" ]] && dh_sha256_ok "$runtime_dest" "$runtime_sha"; then
    ok "runtime de AppImage ya está en caché"
    return 0
  fi
  if [[ -z "$runtime_sha" && "${DH_ALLOW_UNVERIFIED:-0}" != "1" ]]; then
    die "No hay checksum para $runtime en checksums/tools.sha256."
  fi
  dh_fetch "https://github.com/AppImage/type2-runtime/releases/download/continuous/$runtime" \
    "$runtime_dest" "$runtime_sha"
  chmod 0644 "$runtime_dest"
  ok "runtime de AppImage: $runtime_dest"
}

setup_rpm() {
  if dh_have rpmbuild; then
    ok "rpmbuild ya está instalado"
    return 0
  fi
  install_apt rpm
  ok "rpmbuild instalado"
}

setup_exe() {
  local -a missing=()
  dh_have makensis || missing+=(nsis)
  dh_have zip || missing+=(zip)
  if ((${#missing[@]} == 0)); then
    ok "nsis y zip ya están instalados"
    return 0
  fi
  install_apt "${missing[@]}"
  ok "herramientas para .exe instaladas"
}

((do_appimage)) && setup_appimage
((do_rpm))      && setup_rpm
((do_exe))      && setup_exe

ok "herramientas listas"
