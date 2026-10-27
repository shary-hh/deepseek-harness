# deepseek-harness · empaquetado e instalación

Scripts reproducibles para **instalar** y **empaquetar** la CLI
`deepseek-harness` en Linux Mint 22.3 (y derivados de Debian/Ubuntu), Fedora y
Windows.

Genera cuatro formatos desde un mismo payload:

| Formato | Salida | Dónde se usa |
|---|---|---|
| `.deb` | `dist/deepseek-harness_<ver>_amd64.deb` | Linux Mint, Ubuntu, Debian |
| `.rpm` | `dist/deepseek-harness-<ver>-1.x86_64.rpm` | Fedora, RHEL |
| AppImage | `dist/deepseek-harness-<ver>-x86_64.AppImage` | Cualquier Linux (portable) |
| `.exe` + `.zip` | `dist/deepseek-harness-<ver>-win-x64-setup.exe` | Windows 10/11 (x64/arm64) |

> Este repositorio incluye un **esqueleto funcional** de la CLI en `./app/`
> para que puedas generar paquetes desde el primer minuto. Sustitúyelo por tu
> aplicación (ver [Payload](#payload-qué-se-empaqueta)) o apunta `--app-dir`
> a tu proyecto.

---

## Instalación rápida en Linux Mint 22.3

### 1. Modo usuario (recomendado si no quieres tocar el sistema)

```bash
git clone https://github.com/OWNER/deepseek-harness.git
cd deepseek-harness
./install.sh --user
```

Instala en `~/.local/opt/deepseek-harness` y enlaza `~/.local/bin/deepseek-harness`.
No usa `sudo` y no modifica archivos del sistema.

Si `~/.local/bin` no está en tu `PATH`:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

### 2. Modo sistema (todo el equipo)

```bash
./install.sh --system
```

Instala el `.deb` con `apt`, queda en `/opt/deepseek-harness` y
`/usr/bin/deepseek-harness`.

### 3. Desde el código fuente local

```bash
./install.sh --from-source --user
```

Compila el `.deb` con `scripts/build-deb.sh` y lo instala.

### 4. Desde un release publicado

```bash
# Verifica siempre el checksum antes de instalar
./install.sh --version 0.2.0 --sha256 <hash-del-release>
```

### Desinstalar

```bash
./uninstall.sh --user      # o --system
```

Tu configuración personal (`~/.config/deepseek-harness`) **no se borra**.

### Opciones útiles

```text
--dry-run        muestra lo que haría, sin cambios
--yes            sin preguntas (CI)
--gpg-key FILE   verifica SHA256SUMS.asc con tu clave pública
--no-verify      omite checksum (NO recomendado)
--deb FILE       instala un .deb ya descargado
```

Guía detallada: [`docs/INSTALL-LINUX-MINT.md`](docs/INSTALL-LINUX-MINT.md).

---

## Uso de la CLI

La clave se lee **solo** del entorno o de un archivo; nunca se escribe en la
configuración ni se imprime.

```bash
export DEEPSEEK_API_KEY="tu-clave"       # o DEEPSEEK_API_KEY_FILE=~/.secrets/deepseek
# opcional: export DEEPSEEK_API_KEY_FILE="$HOME/.secrets/deepseek" && chmod 600 ...
```

Comandos:

```bash
deepseek-harness chat "Explica qué es un AppImage"
echo "resume este texto" | deepseek-harness chat
deepseek-harness chat --model deepseek-reasoner "razona este problema"
deepseek-harness chat --no-stream --json "respuesta cruda"
deepseek-harness models
deepseek-harness doctor --ping
deepseek-harness config init          # crea ~/.config/deepseek-harness/config.json (0600)
deepseek-harness config set model deepseek-reasoner
deepseek-harness web                   # interfaz gráfica local
```

| Opción de `chat` | Efecto |
|---|---|
| `--model <id>` | Modelo (`deepseek-chat`, `deepseek-reasoner`) |
| `--system <texto>` | Prompt de sistema |
| `--temperature <0..2>` | Creatividad |
| `--max-tokens <n>` | Límite de respuesta |
| `--timeout <ms>` | Tiempo máximo |
| `--stream` / `--no-stream` | Streaming explícito |
| `--json` | JSON completo de la API |

Detalles de seguridad:

- Streaming SSE con `fetch` nativo, sin dependencias.
- La configuración se crea con permisos `0600` y **rechaza** campos como
  `apiKey`, `token` o `secret`.
- `doctor` muestra solo la longitud de la clave, nunca el valor.
- HTTP solo se permite en loopback (para las pruebas); el resto exige HTTPS.

### Interfaz web

```bash
export DEEPSEEK_API_KEY="tu-clave"
deepseek-harness web                 # http://127.0.0.1:8787, token en la URL
deepseek-harness web --port 9000 --open
deepseek-harness web --port 0        # puerto aleatorio
```

- Escucha **solo** en loopback (`127.0.0.1`, `::1`); rechaza `0.0.0.0`.
- Genera un token de sesión y lo entrega en la URL inicial; luego usa una
  cookie `HttpOnly; SameSite=Strict`.
- Comprueba `Host` (anti DNS-rebinding) y `Origin` (anti CSRF).
- La clave de API **nunca llega al navegador**: el servidor local hace las
  llamadas a DeepSeek.
- CSP estricta (`script-src 'self'`, `frame-ancestors 'none'`), sin scripts
  en línea.
- Streaming SSE, selector de modelo, detener respuesta y limpiar conversación.
- Límite de 256 KB por petición y 4 streams simultáneos.

> `v0.1.0` fue el esqueleto de empaquetado. La CLI funcional llega en `v0.2.0`
> y la interfaz web en `v0.3.0`.

---

## Construir los paquetes

Requisitos en Mint 22.3:

```bash
sudo apt update
sudo apt install -y build-essential curl tar gzip dpkg-dev fakeroot
```

Herramientas opcionales por formato:

```bash
./scripts/bootstrap-tools.sh --all     # rpm, nsis, zip y appimagetool
```

| Comando | Qué hace | Requisitos |
|---|---|---|
| `make deb` | `.deb` para amd64/arm64 | `dpkg-deb` |
| `make rpm` | `.rpm` | `rpmbuild` (`apt install rpm`) |
| `make appimage` | AppImage portable | `appimagetool` (lo descarga verificado) |
| `make exe` | ZIP portable + instalador NSIS | `zip`, `makensis` (`apt install nsis`) |
| `make all` | Todo lo posible en la máquina | — |
| `make checksums` | `dist/SHA256SUMS` | `sha256sum` |
| `make test` | Pruebas locales sin red | `bash`, `dpkg-deb`, `node` |

Ejemplos:

```bash
# Empaquetar Node dentro del paquete (recomendado: funciona sin Node instalado)
./scripts/build-deb.sh

# Depender del Node del sistema (paquete más pequeño)
./scripts/build-deb.sh --system-node

# Otra arquitectura (requiere runner nativo para RPM)
./scripts/build-deb.sh --arch arm64

# Ver el árbol generado sin crear el paquete
./scripts/build-deb.sh --stage-only

# Build completo a dist/
./scripts/build-all.sh
```

Detalles de cada formato: [`docs/BUILDING.md`](docs/BUILDING.md).

### ¿Node embebido o del sistema?

- **Embebido (por defecto):** el `.deb` incluye Node.js LTS verificado por
  SHA256. No depende de la versión de Node del usuario. Más pesado (~50 MB).
- **`--system-node`:** el paquete declara `nodejs (>= 20)` / `nodejs >= 20`.
  Más ligero, pero requiere Node moderno en el sistema.

---

## Payload: qué se empaqueta

Los scripts esperan un proyecto Node.js en `./app/` con esta forma:

```text
app/
├── package.json          # name, version, bin
├── dist/cli.js           # entrypoint (o bin/<nombre>)
└── node_modules/         # dependencias de producción
```

Detección del entrypoint, en orden:

1. `dist/cli.js`
2. `bin/deepseek-harness`
3. `index.js`, `cli.js`, `dist/index.js`
4. `package.json` → `bin.<nombre>` → `main`

Para usar otro directorio:

```bash
./scripts/build-deb.sh --app-dir /ruta/a/mi/proyecto
```

### Protección contra fugas

Antes de empaquetar, los scripts **abortan** si encuentran `.env`, `.npmrc`,
`*.pem`, `*.key`, `id_rsa`, `credentials.json`, etc. Si de verdad necesitas
incluirlos (no deberías), usa `--allow-sensitive`.

Nada de tu entorno (`DEEPSEEK_API_KEY`, tokens de npm, etc.) se copia al
paquete: solo se empaqueta el contenido de `./app/`.

---

## Configurar el proyecto

Edita **solo** [`packaging/metadata.env`](packaging/metadata.env):

```bash
APP_HOMEPAGE="https://github.com/tu-usuario/deepseek-harness"
APP_MAINTAINER="Tu Nombre <tu@correo>"
APP_DESC="CLI harness for DeepSeek models"
DH_NODE_VERSION="24.22.1"
```

El owner/repo se autodetecta desde `git remote get-url origin` cuando la
homepage contiene `OWNER`.

La versión sale de `./VERSION`. Para un build puntual: `--version 1.2.3`.

---

## Publicar en GitHub

El repositorio ya está inicializado y con el primer commit hecho. Solo falta
crear el remoto y subirlo:

```bash
# 1. Crea el repositorio vacío en https://github.com/new
#    (sin README, sin .gitignore, sin licencia)

# 2. Conecta y sube
git remote add origin git@github.com:TU-USUARIO/deepseek-harness.git
git push -u origin main

# 3. Publica una versión (dispara el workflow de release)
git tag -a v0.2.0 -m "deepseek-harness 0.2.0"
git push origin v0.2.0
```

> Si prefieres HTTPS: `git remote add origin https://github.com/TU-USUARIO/deepseek-harness.git`.
> Para autenticarte sin exponer el token en el historial, usa
> `git config credential.helper store` **solo** en tu máquina, o el gestor
> de credenciales de tu escritorio.
>
> El commit inicial usa una identidad genérica
> (`DeepSeek Harness <maintainers@users.noreply.github.com>`). Para firmarlo
> con la tuya:
> `git config user.name "Tu Nombre" && git config user.email "tu@correo" && git commit --amend --reset-author --no-edit`.

El workflow [`.github/workflows/release.yml`](.github/workflows/release.yml):

1. construye `.deb` y AppImage en Ubuntu, `.rpm` en un contenedor Fedora y
   `.zip`/`.exe` (cross-build con NSIS) en Ubuntu;
2. genera `SHA256SUMS`;
3. firma con GPG si configuras los secretos `GPG_PRIVATE_KEY`, `GPG_FINGERPRINT`
   y `GPG_PASSPHRASE`;
4. adjunta todo al release de GitHub.

Guía de release y firma: [`docs/RELEASING.md`](docs/RELEASING.md).

### Checksums y firma

```bash
# Verificar artefactos descargados
./scripts/verify-release.sh --dir dist

# Con firma GPG
./scripts/verify-release.sh --dir dist --signature --key pubkey.asc

# Firmar localmente (la passphrase la pide GPG, nunca este script)
DH_GPG_KEY=<fingerprint> ./scripts/sign.sh --file dist/SHA256SUMS
```

---

## Seguridad

Todo lo descargado se verifica con SHA256 fijado en el repo:

- **Node.js**: `SHASUMS256.txt` autenticado con hash pinneado.
- **appimagetool**: hash pinneado en `checksums/tools.sha256`.
- **Paquetes del release**: `SHA256SUMS` + firma GPG opcional.

Además:

- `scripts/scan-secrets.sh` detecta credenciales antes de cada commit (hook
  `.githooks/pre-commit`, activable con `make install-hooks`).
- El instalador crea directorios temporales con permisos `0700` y los borra
  al salir.
- No se usa `curl | bash` ni `eval`.
- No hay telemetría ni llamadas de red más allá de las descargas indicadas.

Lee [`SECURITY.md`](SECURITY.md) para el modelo de amenazas y cómo reportar
vulnerabilidades.

---

## Estructura del repositorio

```text
.
├── install.sh                 # instalador (Mint/Debian/Ubuntu)
├── uninstall.sh               # desinstalador
├── VERSION                    # versión actual
├── app/                       # ← tu payload (ignorado por git)
├── assets/                    # icono PNG
├── checksums/tools.sha256     # hashes de herramientas externas
├── packaging/
│   ├── metadata.env           # metadatos editables
│   ├── common/                # man page
│   ├── deb/                   # control + copyright
│   ├── rpm/                   # spec
│   ├── appimage/              # AppRun + .desktop
│   └── windows/               # NSIS + .cmd + README
├── scripts/
│   ├── lib/                   # common.sh, node.sh, payload.sh
│   ├── build-deb.sh
│   ├── build-rpm.sh
│   ├── build-appimage.sh
│   ├── build-exe.sh
│   ├── build-all.sh
│   ├── bootstrap-tools.sh
│   ├── generate-checksums.sh
│   ├── sign.sh
│   ├── verify-release.sh
│   └── scan-secrets.sh
├── tests/
│   ├── fixtures/app/          # payload mínimo de prueba
│   └── run-tests.sh
├── docs/
└── .github/workflows/         # CI + release
```

---

## Solución de problemas

| Síntoma | Causa / solución |
|---|---|
| `Faltan dependencias: ...` | `sudo apt install <paquete>` o `./scripts/bootstrap-tools.sh --all`. |
| `SHA256 no coincide` | Descarga corrupta o release modificado. **No instales**; vuelve a descargar. |
| `appimagetool no disponible` | `./scripts/bootstrap-tools.sh --appimage` (verifica hash pinneado). |
| `Falta rpmbuild` | `sudo apt install rpm`. |
| `makensis no está instalado` | `sudo apt install nsis`; el ZIP portable se genera igual. |
| `command not found: deepseek-harness` | Añade `~/.local/bin` al `PATH`. |
| El AppImage no arranca por FUSE | `APPIMAGE_EXTRACT_AND_RUN=1 ./deepseek-harness-*.AppImage`. |
| El binario no responde `--version` | Tu payload no implementa `--version`; es solo un aviso. |

---

## Licencia

GPL-3.0-or-later. Ver [`LICENSE`](LICENSE).
