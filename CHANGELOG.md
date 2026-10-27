# Changelog

Todas las cambios relevantes se documentan aquí. Formato basado en
[Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/) y
[SemVer](https://semver.org/lang/es/).

## [0.1.0] - 2026-10-27

### Añadido

- Instalador `install.sh` para Linux Mint 22.x / Debian / Ubuntu con modos
  `--system` y `--user`, `--dry-run` y verificación SHA256/GPG.
- Desinstalador `uninstall.sh` sin tocar configuración personal.
- Empaquetado `.deb` con runtime Node embebido o dependencia `nodejs`.
- Empaquetado `.rpm` para Fedora/RHEL.
- AppImage portable con `appimagetool` verificado.
- ZIP portable e instalador NSIS `.exe` para Windows (x64/arm64), más Node SEA
  experimental.
- CI de pruebas y workflow de release con checksums y firma opcional.
- Escáner de secretos y hook de pre-commit.

### Licencia

- El proyecto se distribuye bajo GNU GPL v3 o posterior (`GPL-3.0-or-later`).
