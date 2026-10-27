'use strict';

/*
 * Workspace de solo lectura para las herramientas del modelo.
 *
 * Reglas de seguridad:
 *  - Todas las rutas se resuelven contra un root real (realpath).
 *  - Se rechazan rutas absolutas, "..", NUL y symlinks que escapen del root.
 *  - Nunca se listan ni leen archivos sensibles (.env, claves, credenciales).
 *  - Los directorios peligrosos (.git, .ssh, node_modules...) se omiten.
 *  - Límites de tamaño y número de entradas para no volcar el workspace.
 */

const fs = require('fs');
const path = require('path');

const { CliError } = require('./core');

const MAX_READ_BYTES = 128 * 1024;
const MAX_ENTRIES = 300;
const MAX_DEPTH = 3;

const BLOCKED_DIRS = new Set([
  '.git', '.hg', '.svn', '.ssh', '.gnupg', '.aws', '.azure', '.kube',
  'node_modules', '.cache', '.npm', '.pnpm-store',
]);

const SENSITIVE_NAMES = [
  /^\.env(\..+)?$/i,
  /^\.npmrc$/i,
  /^\.netrc$/i,
  /^\.git-credentials$/i,
  /^\.htpasswd$/i,
  /^credentials\.json$/i,
  /^id_(rsa|ed25519|ecdsa)(\.pub)?$/i,
  /\.(pem|key|p12|pfx|jks|keystore|kdbx|secret)$/i,
];

function isSensitiveName(name) {
  return SENSITIVE_NAMES.some((pattern) => pattern.test(name));
}

function isBlockedSegment(segment) {
  return BLOCKED_DIRS.has(segment) || isSensitiveName(segment);
}

function inside(root, target) {
  const relative = path.relative(root, target);
  return relative === '' || (!relative.startsWith('..') && !path.isAbsolute(relative));
}

function toRelative(root, absolute) {
  return path.relative(root, absolute) || '.';
}

/**
 * Valida y normaliza el directorio raíz del workspace.
 * Devuelve la ruta real o null si no se pidió workspace.
 */
function resolveWorkspace(dir) {
  if (dir === undefined || dir === null || dir === '') return null;

  const absolute = path.resolve(String(dir));
  let real;
  try {
    real = fs.realpathSync(absolute);
  } catch {
    throw new CliError(`No existe el workspace: ${dir}`);
  }
  if (!fs.statSync(real).isDirectory()) {
    throw new CliError(`El workspace no es un directorio: ${dir}`);
  }
  return real;
}

function resolveTarget(root, requested) {
  const rel = requested === undefined || requested === null ? '.' : String(requested);

  if (rel.includes('\0')) throw new CliError('Ruta inválida.');
  if (path.isAbsolute(rel)) throw new CliError('La ruta debe ser relativa al workspace.');
  if (rel.split(/[\\/]/).some((part) => part === '..')) {
    throw new CliError('La ruta no puede contener "..".');
  }

  const absolute = path.resolve(root, rel);
  if (!inside(root, absolute)) throw new CliError('Ruta fuera del workspace.');

  let real;
  try {
    real = fs.realpathSync(absolute);
  } catch {
    throw new CliError(`No existe en el workspace: ${rel}`);
  }
  if (!inside(root, real)) {
    throw new CliError('La ruta apunta fuera del workspace (symlink).');
  }

  const relative = toRelative(root, real);
  if (relative !== '.') {
    for (const segment of relative.split(path.sep)) {
      if (isBlockedSegment(segment)) {
        throw new CliError(`Ruta bloqueada por seguridad: ${relative}`);
      }
    }
  }

  return real;
}

function listFiles(root, { path: requested = '.', depth = 1 } = {}) {
  const start = resolveTarget(root, requested);
  let level = Number(depth);
  if (!Number.isInteger(level)) level = 1;
  level = Math.min(Math.max(level, 1), MAX_DEPTH);

  const entries = [];
  let truncated = false;

  const walk = (dir, currentDepth) => {
    if (entries.length >= MAX_ENTRIES) {
      truncated = true;
      return;
    }

    let dirents;
    try {
      dirents = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    dirents.sort((a, b) => a.name.localeCompare(b.name));

    for (const dirent of dirents) {
      if (entries.length >= MAX_ENTRIES) {
        truncated = true;
        return;
      }
      if (isBlockedSegment(dirent.name)) continue;

      const full = path.join(dir, dirent.name);
      let stat;
      try {
        stat = fs.lstatSync(full);
      } catch {
        continue;
      }

      const type = stat.isSymbolicLink() ? 'symlink' : stat.isDirectory() ? 'dir' : 'file';
      entries.push({
        path: toRelative(root, full),
        type,
        size: type === 'file' ? stat.size : undefined,
      });

      if (type === 'dir' && currentDepth < level) walk(full, currentDepth + 1);
    }
  };

  walk(start, 1);

  return {
    root: '.',
    path: toRelative(root, start),
    entries,
    truncated,
    limits: { maxEntries: MAX_ENTRIES, maxDepth: MAX_DEPTH },
  };
}

function readFile(root, { path: requested } = {}) {
  if (!requested) throw new CliError('Falta el parámetro "path".');
  const target = resolveTarget(root, requested);

  const name = path.basename(target);
  if (isSensitiveName(name)) {
    throw new CliError(`Archivo bloqueado por seguridad: ${name}`);
  }

  const stat = fs.statSync(target);
  if (!stat.isFile()) throw new CliError('La ruta no es un archivo.');
  if (stat.size > MAX_READ_BYTES) {
    throw new CliError(
      `Archivo demasiado grande (${stat.size} bytes). Máximo: ${MAX_READ_BYTES} bytes.`
    );
  }

  const buffer = fs.readFileSync(target);
  if (buffer.includes(0)) throw new CliError('El archivo parece binario.');

  return {
    path: toRelative(root, target),
    size: buffer.length,
    content: buffer.toString('utf8'),
    truncated: false,
  };
}

const TOOL_DEFINITIONS = [
  {
    type: 'function',
    function: {
      name: 'workspace_list',
      description:
        'List files and directories inside the read-only workspace. ' +
        'Use relative paths only. Sensitive files are hidden.',
      parameters: {
        type: 'object',
        properties: {
          path: { type: 'string', description: 'Relative path inside the workspace. Default "."' },
          depth: { type: 'integer', minimum: 1, maximum: MAX_DEPTH, description: 'Recursion depth (1-3).' },
        },
        additionalProperties: false,
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'workspace_read',
      description:
        'Read a UTF-8 text file inside the read-only workspace (max 128 KB). ' +
        'Sensitive files and binaries are rejected.',
      parameters: {
        type: 'object',
        properties: {
          path: { type: 'string', description: 'Relative path inside the workspace.' },
        },
        required: ['path'],
        additionalProperties: false,
      },
    },
  },
];

function executeTool(root, name, args = {}) {
  if (!root) throw new CliError('Las herramientas requieren un workspace.');
  switch (name) {
    case 'workspace_list':
      return listFiles(root, args);
    case 'workspace_read':
      return readFile(root, args);
    default:
      throw new CliError(`Herramienta desconocida: ${String(name)}`);
  }
}

function summarizeResult(name, result) {
  if (!result || typeof result !== 'object') return 'ok';
  if (name === 'workspace_list') {
    const count = Array.isArray(result.entries) ? result.entries.length : 0;
    return `${count} entradas${result.truncated ? ' (truncado)' : ''}`;
  }
  if (name === 'workspace_read') {
    return `${result.size} bytes`;
  }
  return 'ok';
}

module.exports = {
  resolveWorkspace,
  listFiles,
  readFile,
  executeTool,
  summarizeResult,
  isSensitiveName,
  TOOL_DEFINITIONS,
};
