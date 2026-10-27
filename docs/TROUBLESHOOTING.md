# Solución de problemas

Primero, siempre:

```bash
deepseek-harness doctor --ping
deepseek-harness doctor --workspace ~/dsh-test
```

`doctor` muestra versión de Node, compatibilidad, configuración, proxy, clave
(solo longitud) y valida el workspace sin leer su contenido.

## Node, npm o npx no encontrados

```bash
node --version
npm --version
```

- Instala Node desde https://nodejs.org o con `nvm`.
- Con los paquetes de este repo **no necesitas npm ni npx**: Node va embebido.
- Si usas `--system-node`, el `.deb`/`.rpm` declara `nodejs >= 22.19`.

## Versión de Node no soportada

Rango soportado:

```text
^22.19.0 || >=24.2.0
```

- Node 24.0 y 24.1 tienen un fallo conocido de salida silenciosa; usa 24.2+.
- Node 23 no está en el rango.
- Node 20 y 22.0–22.18 están fuera de soporte.

Síntoma:

```text
error: Node.js v24.1.0 no está soportado.
```

Solución: actualiza Node o usa el paquete con runtime embebido (por defecto).

## `El puerto 8787 ya está en uso`

```bash
deepseek-harness web --port 0        # puerto libre aleatorio
deepseek-harness web --port 9000
```

Comprueba quién ocupa el puerto:

```bash
ss -ltnp | grep 8787
```

## `127.0.0.1:8787` no abre

1. Confirma que el proceso sigue vivo en la terminal (no la cierres).
2. Usa exactamente la URL con token que imprime el comando.
3. Si hay proxy global, excluye loopback:
   ```bash
   export NO_PROXY=127.0.0.1,localhost
   ```
4. Si ejecutas en otra máquina o contenedor, `127.0.0.1` no es tu equipo.
   La interfaz solo escucha en loopback por diseño; no la expongas.

## `No autorizado` / 401 en la web

- La URL inicial lleva un token de un solo uso; si la abres sin token, verás
  401.
- Reinicia `deepseek-harness web` y usa la nueva URL.
- No compartas la URL con token: da acceso a tu sesión local.

## Falta la clave de API

```text
error: Falta la clave de API. Define DEEPSEEK_API_KEY...
```

```bash
export DEEPSEEK_API_KEY="..."
# o
export DEEPSEEK_API_KEY_FILE="$HOME/.secrets/deepseek"
chmod 600 "$HOME/.secrets/deepseek"
```

El archivo debe ser `0600`; `doctor` avisa si es legible por otros usuarios.

## 401, 402 o 429 de DeepSeek

| Código | Significado | Solución |
|---|---|---|
| 401 | Clave inválida o revocada | Crea otra en https://platform.deepseek.com/api_keys |
| 402 | Saldo insuficiente | Recarga tu cuenta |
| 429 | Límite de peticiones | Espera y reintenta |
| 503 | Servicio no disponible | Reintenta más tarde |

La clave nunca se imprime en los errores; si ves `***` es la redacción
intencional.

## Proxy

La app usa `fetch` nativo. En Node 24+ puedes hacer que respete las variables
de entorno:

```bash
export HTTPS_PROXY="http://proxy:8080"
export NO_PROXY="127.0.0.1,localhost"
export NODE_USE_ENV_PROXY=1
deepseek-harness doctor --ping
```

Sin `NODE_USE_ENV_PROXY=1`, Node puede ignorar `HTTPS_PROXY`. `doctor` solo
indica si hay proxy definido, nunca muestra sus credenciales.

## Workspace: permiso denegado o ruta bloqueada

```text
error: La ruta no puede contener "..".
error: La ruta apunta fuera del workspace (symlink).
error: Ruta bloqueada por seguridad: .git/config
error: Archivo bloqueado por seguridad: .env
```

Es el sandbox funcionando. Reglas:

- Solo rutas relativas dentro del workspace.
- Se bloquean `.env`, `.npmrc`, `*.pem`, `*.key`, `id_rsa*`, credenciales,
  `.git`, `.ssh`, `node_modules`.
- Máximo 128 KB por archivo, 300 entradas y profundidad 3.
- Los binarios se rechazan.

Comprueba el workspace:

```bash
deepseek-harness doctor --workspace ~/dsh-test
ls -la ~/dsh-test
```

Usa una carpeta de prueba vacía, no un repositorio de producción.

## `npx @deepseek-ai/dsh web` no es este programa

Ese comando instala el **harness oficial de DeepSeek** (proyecto distinto, con
sus propios perfiles y plugins). Esta app se ejecuta así:

```bash
deepseek-harness web
```

Si quieres el harness oficial, su guía está en
https://deepseekdsh.com/tutorials/linux. No mezcles configuraciones ni claves
entre ambos.

## AppImage no arranca (FUSE)

```bash
APPIMAGE_EXTRACT_AND_RUN=1 ./deepseek-harness-0.4.0-x86_64.AppImage web
```

O instala `libfuse2` en tu distribución.

## El binario instalado no responde

```bash
which deepseek-harness
deepseek-harness --version
ls -l /opt/deepseek-harness/bin/deepseek-harness
```

Si instalaste en modo usuario, comprueba `~/.local/bin` en el `PATH`.
