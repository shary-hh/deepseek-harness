# Política de seguridad

## Qué protege este repositorio

Este repositorio **no contiene la aplicación ni tus claves**. Contiene scripts
de instalación y empaquetado. Aun así, un instalador es un punto de confianza:
si alguien lo modifica, puede ejecutar código con tus privilegios.

Medidas implementadas:

| Riesgo | Mitigación |
|---|---|
| Paquete manipulado en tránsito | `install.sh` verifica `SHA256SUMS` antes de instalar. |
| Checksums manipulados | Firma GPG opcional de `SHA256SUMS.asc` (`--gpg-key`). |
| Dependencias del build trojanizadas | Node.js y appimagetool se descargan con SHA256 fijado. |
| Secretos filtrados al repo | `scripts/scan-secrets.sh` + hook `pre-commit` + CI. |
| Contraseñas en logs/procesos | GPG pide la passphrase por su propio agente; nunca por argumentos. |
| Permisos laxos | Directorios temporales `0700`, paquetes `root:root`, archivos `0644/0755`. |
| Instalación silenciosa | `--dry-run`, confirmaciones y `--yes` explícito. |

## Lo que el proyecto NO hace

- No incluye ni solicita `DEEPSEEK_API_KEY`.
- No escribe claves de API en disco.
- No envía telemetría.
- No ejecuta `curl | bash` ni evalúa código descargado.
- No modifica tu `~/.bashrc` sin avisarte (solo imprime la línea de `PATH`).

## Tus responsabilidades

1. Guarda tu API key en un gestor de secretos o en el entorno de tu shell.
2. Verifica siempre el SHA256 (y la firma GPG si existe) de lo que descargas.
3. No ejecutes el instalador como root si solo necesitas `--user`.
4. Revisa `git diff` antes de publicar tu fork.

## Reportar una vulnerabilidad

Usa **GitHub Security Advisories** (pestaña *Security* → *Report a vulnerability*)
en lugar de abrir un issue público. Incluye:

- versión afectada y sistema operativo,
- pasos de reproducción,
- impacto esperado.

Objetivo de respuesta: 72 horas para acuse, 30 días para corrección o plan.

## Versiones soportadas

| Versión | Soportada |
|---|---|
| 0.1.x | Sí |
| < 0.1 | No |
