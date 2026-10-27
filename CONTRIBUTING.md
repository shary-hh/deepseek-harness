# Contribuir

Gracias por ayudar. Este repo empaqueta una CLI en Node.js para cuatro
plataformas; cualquier cambio debe mantener los cuatro builds funcionando.

## Flujo

```bash
git clone <tu-fork>
cd deepseek-harness
make install-hooks   # activa pre-commit (bash -n + scan-secrets)
make test
```

## Reglas

1. **Nunca** subas `.env`, claves, tokens ni certificados. El hook lo bloquea.
2. Todo script nuevo debe pasar `bash -n` y `shellcheck -x -S error`.
3. Toda descarga nueva debe llevar SHA256 fijado en `checksums/`.
4. No añadas dependencias que no estén en los repos oficiales de Mint/Ubuntu.
5. Mantén los mensajes en español, claros y sin jerga innecesaria.
6. Si tocas el layout del payload, actualiza `tests/run-tests.sh`.

## Estructura

- `scripts/build-*.sh`: un formato por script, idempotente y con `--stage-only`.
- `scripts/lib/`: utilidades compartidas (no ejecutar directamente).
- `packaging/`: plantillas específicas de cada formato.
- `tests/fixtures/app/`: payload mínimo para probar sin red.

## Pull requests

- Un cambio por PR.
- Describe qué formato afecta y cómo lo probaste.
- Adjunta la salida de `make test` (o el fragmento relevante).
