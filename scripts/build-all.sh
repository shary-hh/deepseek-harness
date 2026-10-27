#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Construye todos los artefactos posibles en esta máquina.
#
# Uso: scripts/build-all.sh [opciones]
# ---------------------------------------------------------------------------
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<'EOF'
Construye todos los artefactos disponibles.

Uso: scripts/build-all.sh [opciones]

  --version VERSION   Versión (por defecto: ./VERSION)
  --arch ARCH         amd64/arm64 (por defecto: host)
  --system-node       No empaquetar Node (los paquetes dependerán del sistema)
  --allow-sensitive   No abortar si el payload tiene archivos sensibles
  --skip-deb | --skip-rpm | --skip-appimage | --skip-exe
  --ci                Sin preguntas; instala herramientas con apt si hace falta
  -h, --help          Ayuda

Los formatos cuya herramienta no esté disponible se omiten con un aviso.
EOF
}

PASSTHRU=()
CI=0
SKIP_DEB=0 SKIP_RPM=0 SKIP_APPIMAGE=0 SKIP_EXE=0

while (($#)); do
  case "$1" in
    --version|--arch) PASSTHRU+=( "$1" "${2:?$1 requiere un valor}" ); shift 2 ;;
    --system-node|--allow-sensitive) PASSTHRU+=( "$1" ); shift ;;
    --skip-deb) SKIP_DEB=1; shift ;;
    --skip-rpm) SKIP_RPM=1; shift ;;
    --skip-appimage) SKIP_APPIMAGE=1; shift ;;
    --skip-exe) SKIP_EXE=1; shift ;;
    --ci) CI=1; export ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Opción desconocida: $1" ;;
  esac
done

dh_banner "build-all"
dh_prepare_dirs

declare -a BUILT=() SKIPPED=() FAILED=()

run_step() {
  local name="$1"; shift
  log "── $name ──────────────────────────────────────────────"
  if "$@"; then
    BUILT+=("$name")
  else
    FAILED+=("$name")
    warn "falló: $name"
  fi
}

if ((SKIP_DEB == 0)); then
  run_step "deb" "$SCRIPT_DIR/build-deb.sh" "${PASSTHRU[@]}"
else
  SKIPPED+=("deb")
fi

if ((SKIP_RPM == 0)); then
  if dh_have rpmbuild; then
    run_step "rpm" "$SCRIPT_DIR/build-rpm.sh" "${PASSTHRU[@]}"
  elif ((CI)); then
    "$SCRIPT_DIR/bootstrap-tools.sh" --rpm --yes
    run_step "rpm" "$SCRIPT_DIR/build-rpm.sh" "${PASSTHRU[@]}"
  else
    warn "rpmbuild no disponible; se omite rpm (scripts/bootstrap-tools.sh --rpm)"
    SKIPPED+=("rpm")
  fi
else
  SKIPPED+=("rpm")
fi

if ((SKIP_APPIMAGE == 0)); then
  if ((CI)); then
    "$SCRIPT_DIR/bootstrap-tools.sh" --appimage --yes || true
  fi
  run_step "appimage" "$SCRIPT_DIR/build-appimage.sh" "${PASSTHRU[@]}"
else
  SKIPPED+=("appimage")
fi

if ((SKIP_EXE == 0)); then
  if ((CI)); then
    "$SCRIPT_DIR/bootstrap-tools.sh" --exe --yes || true
  fi
  run_step "exe" "$SCRIPT_DIR/build-exe.sh" "${PASSTHRU[@]}"
else
  SKIPPED+=("exe")
fi

dh_write_checksums "$DH_DIST_DIR"

log "── resumen ────────────────────────────────────────────"
for f in "$DH_DIST_DIR"/*; do
  [[ -f "$f" ]] || continue
  printf '  %-52s %8s\n' "$(basename -- "$f")" "$(du -h "$f" | cut -f1)" >&2
done
(( ${#SKIPPED[@]} == 0 )) || warn "omitidos: ${SKIPPED[*]}"

if (( ${#FAILED[@]} > 0 )); then
  die "fallaron: ${FAILED[*]}"
fi
ok "artefactos en $DH_DIST_DIR"
