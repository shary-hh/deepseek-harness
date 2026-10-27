# Publicar un release

## 1. Preparar la versión

```bash
# 1. Actualiza VERSION
echo "0.2.0" > VERSION

# 2. Actualiza CHANGELOG.md

# 3. Pruebas
make lint
make test

# 4. Commit y tag
git add VERSION CHANGELOG.md
git commit -m "chore(release): 0.2.0"
git tag -a v0.2.0 -m "deepseek-harness 0.2.0"
git push origin main
git push origin v0.2.0
```

El tag `v*` dispara `.github/workflows/release.yml`.

## 2. Qué construye el workflow

| Job | Runner | Artefactos |
|---|---|---|
| `linux-deb` | `ubuntu-22.04` | `.deb` amd64 |
| `linux-appimage` | `ubuntu-22.04` | `.AppImage` x86_64 |
| `linux-rpm` | contenedor `fedora:41` | `.rpm` x86_64 |
| `windows` | `windows-latest` | `.zip` + `-setup.exe` |
| `release` | `ubuntu-24.04` | `SHA256SUMS` (+ `.asc`) y release |

`ubuntu-22.04` se usa para que el `.deb` funcione en glibc más antiguas.

## 3. Firma GPG (recomendado)

Configura en **Settings → Secrets and variables → Actions**:

| Secreto | Contenido |
|---|---|
| `GPG_PRIVATE_KEY` | clave privada exportada en ASCII armor |
| `GPG_FINGERPRINT` | fingerprint de la clave |
| `GPG_PASSPHRASE` | passphrase (opcional si la clave no tiene) |

Genera la clave **fuera del repo**:

```bash
gpg --full-generate-key
gpg --armor --export-secret-keys "$FINGERPRINT" > /tmp/private.asc
# copia el contenido a GitHub Secrets y borra /tmp/private.asc
```

Si no configuras estos secretos, el release se publica igualmente pero sin
`SHA256SUMS.asc`. Los usuarios verán un aviso al verificar.

## 4. Verificar el release

```bash
gh release download v0.2.0
./scripts/verify-release.sh --dir . --signature --key pubkey.asc
```

O manualmente:

```bash
sha256sum -c SHA256SUMS
gpg --verify SHA256SUMS.asc SHA256SUMS
```

## 5. Instalar el release

```bash
./install.sh --version 0.2.0
```

## Notas

- No publiques binarios construidos en tu máquina sin pasar por CI: el runner
  limpio evita contaminación del entorno.
- Fija las acciones por versión mayor (`@v4`); para paranoia de supply chain,
  fíjalas por SHA de commit.
- Si un build falla por checksum de appimagetool, no lo saltes con
  `DH_ALLOW_UNVERIFIED=1` en CI: actualiza el pin tras revisar el binario.
