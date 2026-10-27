#!/usr/bin/env bash
# shellcheck shell=bash
# ---------------------------------------------------------------------------
# Preparación del payload (el "contenido" que va dentro de cada paquete).
#
# Layout generado:
#   DEST/bin/<bin>                 lanzador POSIX
#   DEST/lib/app/...               aplicación Node (dist/ + node_modules/)
#   DEST/lib/node/bin/node         runtime Node (si no es --system-node)
#   DEST/share/doc/<name>/         LICENSE / copyright
#   DEST/share/man/man1/<bin>.1    página de manual
# ---------------------------------------------------------------------------

[[ -n "${DH_PAYLOAD_LOADED:-}" ]] && return 0
DH_PAYLOAD_LOADED=1

# Archivos que NUNCA deben empaquetarse.
DH_SENSITIVE_NAMES=(
  '.env' '.env.*' '.npmrc' '.git-credentials' '.netrc'
  '*.pem' '*.key' '*.p12' '*.pfx' '*.jks' '*.keystore'
  'id_rsa*' 'id_ed25519*' 'id_ecdsa*'
  'credentials.json' '*.kdbx' '*.secret'
)

dh_find_sensitive() {
  local dir="$1"
  local -a args=()
  local pattern
  for pattern in "${DH_SENSITIVE_NAMES[@]}"; do
    args+=( -o -name "$pattern" )
  done
  # Quita el primer -o
  find "$dir" -type f \( "${args[@]:1}" \) \
    ! -name ".env.example" ! -name ".env.sample" -print 2>/dev/null || true
}

# Aborta si el payload contiene material sensible. Es una red de seguridad,
# no un antivirus: revisa siempre qué estás empaquetando.
dh_assert_no_sensitive() {
  local dir="$1" found
  found="$(dh_find_sensitive "$dir")"
  if [[ -n "$found" ]]; then
    printf '%s\n' "$found" >&2
    die "El payload contiene archivos potencialmente sensibles (ver lista arriba).
       Elimínalos o usa DH_ALLOW_SENSITIVE=1 si de verdad deben ir dentro del paquete."
  fi
}

dh_json_field() {
  local file="$1" expr="$2"
  python3 - "$file" "$expr" <<'PY' 2>/dev/null || return 1
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
cur = data
for part in sys.argv[2].split("."):
    if not isinstance(cur, dict) or part not in cur:
        raise SystemExit(1)
    cur = cur[part]
if isinstance(cur, (dict, list)):
    raise SystemExit(1)
print(cur)
PY
}

# Devuelve la ruta relativa del entrypoint Node.
dh_resolve_entrypoint() {
  local app="$1" candidate bin
  for candidate in "dist/cli.js" "bin/$APP_BIN" "index.js" "cli.js" "dist/index.js"; do
    if [[ -f "$app/$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done

  if [[ -f "$app/package.json" ]]; then
    bin="$(dh_json_field "$app/package.json" "bin.$APP_BIN" || true)"
    if [[ -z "$bin" ]]; then
      bin="$(dh_json_field "$app/package.json" "bin" || true)"
    fi
    if [[ -z "$bin" ]]; then
      bin="$(dh_json_field "$app/package.json" "main" || true)"
    fi
    bin="${bin#./}"
    if [[ -n "$bin" && -f "$app/$bin" ]]; then
      printf '%s' "$bin"
      return 0
    fi
  fi

  die "No se encontró entrypoint Node en $app (busca dist/cli.js, bin/$APP_BIN o package.json#bin)."
}

dh_validate_relpath() {
  local p="$1"
  [[ -n "$p" ]] || die "Ruta vacía."
  [[ "$p" != /* ]] || die "La ruta debe ser relativa: $p"
  [[ "$p" != *..* ]] || die "La ruta no puede contener '..': $p"
  [[ "$p" =~ ^[A-Za-z0-9._/+@-]+$ ]] || die "La ruta contiene caracteres no permitidos: $p"
}

# Escribe el lanzador. Uso: dh_write_launcher DEST ENTRY [system]
dh_write_launcher() {
  local dest="$1" entry="$2" mode="${3:-bundled}"
  local launcher="$dest/bin/$APP_BIN"

  dh_validate_relpath "$entry"
  mkdir -p "$dest/bin"

  if [[ "$mode" == "system" ]]; then
    cat > "$launcher" <<'EOF'
#!/bin/sh
# deepseek-harness - lanzador generado automáticamente.
set -eu
self=$0
while [ -L "$self" ]; do
  target=$(readlink "$self")
  case $target in
    /*) self=$target ;;
    *)  self=$(dirname -- "$self")/$target ;;
  esac
done
root=$(CDPATH= cd -- "$(dirname -- "$self")/.." && pwd -P)
NODE_BIN=${DH_NODE_BIN:-node}
if ! command -v "$NODE_BIN" >/dev/null 2>&1; then
  echo "deepseek-harness: se requiere Node.js >= 20 (variable DH_NODE_BIN para personalizar)." >&2
  exit 127
fi
exec "$NODE_BIN" "$root/lib/app/__ENTRY__" "$@"
EOF
  else
    cat > "$launcher" <<'EOF'
#!/bin/sh
# deepseek-harness - lanzador generado automáticamente.
set -eu
self=$0
while [ -L "$self" ]; do
  target=$(readlink "$self")
  case $target in
    /*) self=$target ;;
    *)  self=$(dirname -- "$self")/$target ;;
  esac
done
root=$(CDPATH= cd -- "$(dirname -- "$self")/.." && pwd -P)
exec "$root/lib/node/bin/node" "$root/lib/app/__ENTRY__" "$@"
EOF
  fi

  sed -i "s|__ENTRY__|$entry|g" "$launcher"
  chmod 0755 "$launcher"
}

dh_copy_common_files() {
  local dest="$1"
  install -d -m 0755 "$dest/share/doc/$APP_NAME" "$dest/share/man/man1"

  if [[ -r "$REPO_ROOT/LICENSE" ]]; then
    install -m 0644 "$REPO_ROOT/LICENSE" "$dest/share/doc/$APP_NAME/LICENSE"
  fi
  if [[ -r "$REPO_ROOT/packaging/common/$APP_BIN.1" ]]; then
    install -m 0644 "$REPO_ROOT/packaging/common/$APP_BIN.1" "$dest/share/man/man1/$APP_BIN.1"
  fi
}

# Avisa si la versión del payload no coincide con VERSION (el binario
# mostraría una versión distinta a la del paquete).
dh_check_payload_version() {
  local app="$1" app_ver pkg_ver
  [[ -f "$app/package.json" ]] || return 0
  app_ver="$(dh_json_field "$app/package.json" version || true)"
  pkg_ver="$(dh_version)"
  if [[ -n "$app_ver" && "$app_ver" != "$pkg_ver" ]]; then
    warn "app/package.json declara $app_ver pero VERSION es $pkg_ver."
    warn "El binario mostrará $app_ver; sincroniza ambos antes de publicar."
  fi
}

# Uso: dh_stage_payload DEST [bundled|system]
dh_stage_payload() {
  local dest="$1" mode="${2:-bundled}"
  local entry

  [[ -d "$DH_APP_DIR" ]] || die "No existe el payload: $DH_APP_DIR (usa --app-dir)."
  [[ "${DH_ALLOW_SENSITIVE:-0}" == "1" ]] || dh_assert_no_sensitive "$DH_APP_DIR"
  dh_check_payload_version "$DH_APP_DIR"

  mkdir -p "$dest/lib/app" "$dest/bin"

  log "copiando payload desde $(basename -- "$DH_APP_DIR")"
  tar -C "$DH_APP_DIR" \
    --exclude='./.git' --exclude='./.github' --exclude='./.gitignore' \
    --exclude='./node_modules/.cache' \
    -cf - . | tar -C "$dest/lib/app" -xf -

  entry="$(dh_resolve_entrypoint "$dest/lib/app")"
  log "entrypoint: $entry"

  if [[ "$mode" == "system" ]]; then
    dh_write_launcher "$dest" "$entry" system
  else
    dh_write_launcher "$dest" "$entry" bundled
    dh_node_install_linux "$(dh_norm_arch "${DH_ARCH:-}")" "$dest"
  fi

  dh_copy_common_files "$dest"

  # Permisos reproducibles: sin bits raros ni archivos de usuario.
  find "$dest" -type d -exec chmod 0755 {} +
  find "$dest" -type f -exec chmod 0644 {} +
  chmod 0755 "$dest/bin/$APP_BIN"
  if [[ -f "$dest/lib/node/bin/node" ]]; then
    chmod 0755 "$dest/lib/node/bin/node"
  fi

  ok "payload listo en $(basename -- "$dest")"
}
