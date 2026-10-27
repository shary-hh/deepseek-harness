# deepseek-harness (aplicación)

CLI y web local para la API de DeepSeek, sin dependencias externas. Usa
`fetch` nativo de Node.js >= 20.

## Uso

```bash
export DEEPSEEK_API_KEY="..."   # nunca se guarda en disco

node app/dist/cli.js --help
node app/dist/cli.js chat "Explica qué es un AppImage"
echo "resume este texto" | node app/dist/cli.js chat
node app/dist/cli.js chat --model deepseek-reasoner "razona esto"
node app/dist/cli.js models
node app/dist/cli.js doctor --ping
node app/dist/cli.js config init
node app/dist/cli.js web --open
```

## Interfaz web

`deepseek-harness web` escucha en `127.0.0.1:8787` (configurable con
`--port`), exige un token de sesión y nunca envía la clave al navegador.
`--port 0` elige un puerto libre; `--open` abre el navegador.

## Seguridad

- La clave vive en `DEEPSEEK_API_KEY` o en `DEEPSEEK_API_KEY_FILE` (0600).
- `config.json` se crea con modo `0600` y **rechaza** campos tipo `apiKey`,
  `token`, `secret`, etc.
- `doctor` muestra solo la longitud de la clave, nunca su valor.
- Los errores HTTP se redactan antes de imprimirse.
- Solo se permite HTTP en loopback; el resto exige HTTPS.

## Sustituir por tu propia app

El contrato de empaquetado es:

```text
app/
├── package.json     # "bin": { "deepseek-harness": "dist/cli.js" }
├── dist/cli.js      # entrypoint
└── node_modules/    # dependencias de producción (si las hay)
```

Puedes reemplazar `app/` por tu proyecto y reconstruir con:

```bash
./scripts/build-deb.sh --app-dir /ruta/a/tu/proyecto
```

## Pruebas

```bash
node --test tests/cli.test.js
```

Usan un servidor HTTP local; no tocan la red real ni claves reales.
