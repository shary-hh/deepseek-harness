# Payload de la aplicación

Este directorio contiene un **esqueleto funcional** de la CLI para que el
repositorio pueda generar paquetes desde el primer momento.

## Sustitúyelo por tu app

Opción A — copiar tu proyecto aquí:

```bash
rm -rf app
cp -a /ruta/a/tu/proyecto app
# instala solo dependencias de producción
( cd app && npm ci --omit=dev )
```

Opción B — dejar tu proyecto donde está:

```bash
./scripts/build-deb.sh --app-dir /ruta/a/tu/proyecto
```

## Contrato mínimo

```text
app/
├── package.json     # "bin": { "deepseek-harness": "dist/cli.js" }
├── dist/cli.js      # entrypoint CommonJS o ESM
└── node_modules/    # dependencias de producción
```

- El entrypoint debe ser ejecutable con el Node embebido (>= 20).
- No incluyas `.env`, claves ni certificados: el build aborta si los detecta.
- No imprimas `DEEPSEEK_API_KEY` en logs.

## Probar sin empaquetar

```bash
node app/dist/cli.js --help
node app/dist/cli.js doctor
```
