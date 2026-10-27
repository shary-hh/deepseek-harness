# Instalar en Linux Mint 22.3 (Zena)

Probado en Linux Mint 22.3 con glibc 2.39 y bash 5.2. El instalador también
funciona en Ubuntu 24.04+ y Debian 12+.

## Requisitos

```bash
sudo apt update
sudo apt install -y curl tar gzip coreutils dpkg
```

El paquete `.deb` **no necesita Node.js** si se construyó con el runtime
embebido (opción por defecto).

## Instalación

### A) Modo usuario (sin sudo)

```bash
git clone https://github.com/OWNER/deepseek-harness.git
cd deepseek-harness
./install.sh --user
```

Resultado:

```text
~/.local/opt/deepseek-harness/     # aplicación + runtime
~/.local/bin/deepseek-harness      # symlink
~/.local/share/man/man1/...        # man page
```

Verifica:

```bash
~/.local/bin/deepseek-harness --help
```

### B) Modo sistema (con sudo)

```bash
./install.sh --system
```

Resultado:

```text
/opt/deepseek-harness/             # aplicación + runtime
/usr/bin/deepseek-harness          # symlink
/usr/share/man/man1/deepseek-harness.1.gz
/usr/share/doc/deepseek-harness/
```

Verifica:

```bash
deepseek-harness --help
dpkg -s deepseek-harness
```

### C) Instalación sin clonar el repo

Descarga el `.deb` y el `SHA256SUMS` del release, verifica y luego:

```bash
sudo apt install ./deepseek-harness_0.1.0_amd64.deb
```

O usa el instalador con el hash fuera de banda:

```bash
./install.sh --version 0.1.0 --sha256 <hash>
```

## Qué escribe exactamente el instalador

- El `.deb` en `dist/` o la caché temporal del release.
- `/opt/deepseek-harness` y `/usr/bin/deepseek-harness` (modo sistema).
- `~/.local/opt/...` (modo usuario).
- **Nada más.** No toca `.bashrc`, no crea servicios, no escribe claves.

El directorio temporal se crea con permisos `0700` y se elimina con `trap` al
salir, incluso si hay error.

## Verificación de integridad

```bash
sha256sum -c SHA256SUMS
gpg --verify SHA256SUMS.asc SHA256SUMS   # si el release está firmado
```

O con el script incluido:

```bash
./scripts/verify-release.sh --dir dist --signature --key pubkey.asc
```

Si el checksum no coincide, **detente**. No existe una razón legítima para que
un `.deb` cambie sin cambiar la versión.

## Instalación offline

1. En una máquina con red, descarga el `.deb` y `SHA256SUMS`.
2. Copia ambos por USB.
3. Verifica el hash en la máquina destino.
4. `sudo apt install ./deepseek-harness_<ver>_amd64.deb`.

El paquete embebido no descarga nada durante la instalación.

## Clave de API (importante)

El instalador **no** pide ni guarda tu clave. Configúrala en tu entorno:

```bash
export DEEPSEEK_API_KEY="..."   # solo en tu shell o gestor de secretos
```

Recomendaciones:

- No la pongas en `~/.bashrc` de una máquina compartida.
- Usa `pass`, `gopass`, `1Password CLI` o el llavero de tu escritorio.
- Nunca la incluyas en `./app/`: el empaquetador abortaría igualmente.

## Desinstalar

```bash
./uninstall.sh --user
# o
./uninstall.sh --system
```

La configuración personal en `~/.config/deepseek-harness` **no se elimina**.
Bórrala manualmente si lo deseas.

## Problemas conocidos

| Problema | Solución |
|---|---|
| `apt` pide dependencias que no existen | Usa el paquete con Node embebido (sin `--system-node`). |
| `deepseek-harness: command not found` | `export PATH="$HOME/.local/bin:$PATH"`. |
| Conflicto con una versión previa instalada a mano | `./uninstall.sh --user` y revisa `~/.local/opt`. |
| `dpkg: error: ... permission denied` | No uses `sudo` con `--user`; usa `--system`. |
