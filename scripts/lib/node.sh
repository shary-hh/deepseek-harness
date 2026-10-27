#!/usr/bin/env bash
# shellcheck shell=bash
# ---------------------------------------------------------------------------
# Descarga y verificación del runtime de Node.js que se empaqueta.
#
# Fuente: https://nodejs.org/dist  (HTTPS, con pin de checksums)
# Formato de SHASUMS256.txt:
#   <sha256>  node-vX.Y.Z-linux-x64.tar.xz
#   <sha256>  win-x64/node.exe
# ---------------------------------------------------------------------------

[[ -n "${DH_NODE_LOADED:-}" ]] && return 0
DH_NODE_LOADED=1

# Hash del archivo SHASUMS256.txt para la versión fijada. Si cambias
# DH_NODE_VERSION debes actualizar este valor (o definir DH_NODE_SHASUMS_SHA256).
dh_node_shasums_expected() {
  case "$DH_NODE_VERSION" in
    24.22.1) printf '%s' 'fdfbffc969c0f604beff0124d409b33a43b53f5c681d6220f80023e0d6df9dc4' ;;
    *)       printf '%s' "${DH_NODE_SHASUMS_SHA256:-}" ;;
  esac
}

dh_node_platform_linux() {
  case "$(dh_norm_arch "${1:-}")" in
    x86_64)  printf 'linux-x64' ;;
    aarch64) printf 'linux-arm64' ;;
  esac
}

dh_node_platform_win() {
  case "$(dh_norm_arch "${1:-}")" in
    x86_64)  printf 'win-x64' ;;
    aarch64) printf 'win-arm64' ;;
  esac
}

dh_node_dist_base() {
  printf 'https://nodejs.org/dist/v%s' "$DH_NODE_VERSION"
}

dh_node_shasums() {
  local dest="$DH_CACHE_DIR/SHASUMS256-v$DH_NODE_VERSION.txt"
  local expected
  expected="$(dh_node_shasums_expected)"
  dh_fetch "$(dh_node_dist_base)/SHASUMS256.txt" "$dest" "$expected"
  printf '%s' "$dest"
}

# Devuelve el SHA256 publicado para un miembro concreto del release.
dh_node_expected_sha() {
  local member="$1" shasums sha
  shasums="$(dh_node_shasums)"
  sha="$(awk -v f="$member" '$2 == f { print $1; exit }' "$shasums")"
  [[ -n "$sha" ]] || die "No se encontró '$member' en SHASUMS256.txt de Node $DH_NODE_VERSION"
  printf '%s' "$sha"
}

# Instala Node (binario + licencia) en DEST/lib/node.
# Uso: dh_node_install_linux ARCH DEST
dh_node_install_linux() {
  local arch="$1" dest="$2"
  local platform member url tarball sha tmp
  platform="$(dh_node_platform_linux "$arch")"
  member="node-v${DH_NODE_VERSION}-${platform}.tar.xz"
  url="$(dh_node_dist_base)/$member"
  sha="$(dh_node_expected_sha "$member")"
  tarball="$DH_CACHE_DIR/$member"

  dh_fetch "$url" "$tarball" "$sha"

  tmp="$(mktemp -d "$DH_CACHE_DIR/extract.XXXXXX")"

  if ! tar -xJf "$tarball" -C "$tmp" --strip-components=1 \
    "node-v${DH_NODE_VERSION}-${platform}/bin/node" \
    "node-v${DH_NODE_VERSION}-${platform}/LICENSE"; then
    rm -rf -- "$tmp"
    die "No se pudo extraer $tarball"
  fi

  install -d -m 0755 "$dest/lib/node/bin"
  install -m 0755 "$tmp/bin/node" "$dest/lib/node/bin/node"
  install -m 0644 "$tmp/LICENSE" "$dest/lib/node/LICENSE"
  printf '%s\n' "$DH_NODE_VERSION" > "$dest/lib/node/VERSION"
  chmod 0644 "$dest/lib/node/VERSION"
  rm -rf -- "$tmp"
  ok "Node $DH_NODE_VERSION empaquetado ($platform)"
}

# Descarga node.exe para Windows y lo deja en DEST.
# Uso: dh_node_install_windows ARCH DESTDIR
dh_node_install_windows() {
  local arch="$1" dest="$2"
  local platform member url sha
  platform="$(dh_node_platform_win "$arch")"
  member="${platform}/node.exe"
  url="$(dh_node_dist_base)/$member"
  sha="$(dh_node_expected_sha "$member")"

  mkdir -p "$dest"
  dh_fetch "$url" "$dest/node.exe" "$sha"
  chmod 0755 "$dest/node.exe"
  ok "node.exe $DH_NODE_VERSION empaquetado ($platform)"
}
