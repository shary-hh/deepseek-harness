# Construir los paquetes

Todos los scripts:

- se ejecutan desde cualquier directorio,
- aceptan `--version`, `--arch`, `--app-dir`, `--output-dir`,
- tienen `--stage-only` para inspeccionar el árbol sin generar el artefacto,
- escriben en `dist/` por defecto,
- usan `build/` para el staging (borrable con `make clean`).

## Matriz de compatibilidad

| Formato | Host de build | Arquitecturas | Herramienta |
|---|---|---|---|
| `.deb` | Debian/Ubuntu/Mint | amd64, arm64 | `dpkg-deb` |
| `.rpm` | Fedora/RHEL (o Ubuntu con `rpm`) | x86_64, aarch64 (nativo) | `rpmbuild` |
| AppImage | Linux x86_64/aarch64 | igual que el host | `appimagetool` |
| `.exe` / `.zip` | Linux/macOS con bash | x64, arm64 | `makensis`, `zip` |

## `.deb`

```bash
./scripts/build-deb.sh
# dist/deepseek-harness_0.2.0_amd64.deb

dpkg-deb --info dist/deepseek-harness_0.2.0_amd64.deb
dpkg-deb -c   dist/deepseek-harness_0.2.0_amd64.deb
```

- Layout: `/opt/deepseek-harness/{bin,lib}`, symlink en `/usr/bin`.
- `Depends`: `libc6 (>= 2.28), libgcc-s1` (Node embebido) o
  `nodejs (>= 22.19)` con `--system-node`.
- Incluye `DEBIAN/md5sums`, `copyright` y man page comprimida.
- `--root-owner-group` evita depender de `fakeroot` en dpkg moderno.

## `.rpm`

```bash
sudo apt install rpm        # en Mint/Ubuntu
./scripts/build-rpm.sh
# dist/deepseek-harness-0.2.0-1.x86_64.rpm
```

- `AutoReqProv: no` porque el runtime Node va embebido.
- `%files` declara `/opt/deepseek-harness`, el symlink y la man page.
- El RPM debe construirse en la arquitectura destino. Para aarch64 usa un
  runner nativo (el workflow de release lo hace en Fedora).
- `--stage-only` genera el spec en `build/rpm/SPECS/`.

## AppImage

```bash
./scripts/bootstrap-tools.sh --appimage   # descarga verificada
./scripts/build-appimage.sh
```

- AppDir: `usr/lib/deepseek-harness`, `AppRun`, `.desktop` y icono 256×256.
- `APPIMAGE_EXTRACT_AND_RUN=1` evita depender de FUSE durante el build.
- `--no-appstream` evita llamadas de red de appimagetool.

El binario de `appimagetool` está pinneado en `checksums/tools.sha256`. Si
upstream reconstruye el release `continuous`, el build fallará por checksum:
es intencional. Verifica el binario y actualiza el hash de forma consciente.

## Windows: ZIP y EXE

```bash
sudo apt install nsis zip
./scripts/build-exe.sh
```

Genera:

```text
dist/deepseek-harness-0.2.0-win-x64.zip        # portable
dist/deepseek-harness-0.2.0-win-x64-setup.exe  # instalador NSIS
```

- El ZIP incluye `node.exe` (verificado), `app/`, el lanzador `.cmd` y `LICENSE`.
- El instalador NSIS copia a `%ProgramFiles%\deepseek-harness`, añade al
  `PATH` del sistema **guardando una copia** para restaurarla al desinstalar.
- No requiere Visual Studio ni Wine.

### Node SEA (experimental)

```bash
./scripts/build-exe.sh --sea
```

Genera además un `.exe` único con `node --experimental-sea-config` +
`postject`. Limitaciones:

- requiere `esbuild` (vía `npx`) para bundlear dependencias,
- los módulos nativos (`.node`) no funcionan,
- el `.exe` resultante pierde la firma Authenticode de Node.

Para producción, el ZIP/NSIS es la opción recomendada.

## Checksums y firma

```bash
./scripts/generate-checksums.sh            # dist/SHA256SUMS
DH_GPG_KEY=<fingerprint> ./scripts/sign.sh --file dist/SHA256SUMS
./scripts/verify-release.sh --dir dist --signature
```

## Actualizar Node.js

1. Cambia `DH_NODE_VERSION` en `packaging/metadata.env`.
2. Actualiza el hash de `SHASUMS256.txt` en `scripts/lib/node.sh`
   (`dh_node_shasums_expected`).
3. Ejecuta `make test` y un build real.

Los hashes por archivo se leen del `SHASUMS256.txt` autenticado: no hay que
copiarlos a mano.

## Actualizar appimagetool

```bash
curl -fsSL -o /tmp/appimagetool \
  https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage
sha256sum /tmp/appimagetool
# compara con el release upstream y actualiza checksums/tools.sha256
```
