'use strict';

/*
 * Núcleo compartido: configuración, credenciales y cliente HTTP de DeepSeek.
 * Lo usan tanto la CLI (cli.js) como la interfaz web (web-server.js).
 *
 * La clave de API NUNCA se escribe en la configuración ni se registra.
 */

const fs = require('fs');
const os = require('os');
const path = require('path');

const DEFAULT_BASE_URL = 'https://api.deepseek.com';
const DEFAULT_MODEL = 'deepseek-chat';
const DEFAULT_TIMEOUT_MS = 120000;
const DEFAULT_MAX_TOKENS = 4096;

const SECRET_FIELD = /^(api[_-]?key|apikey|key|token|access[_-]?token|secret|client[_-]?secret|password|credentials)$/i;

const CONFIG_FIELDS = new Set([
  'baseUrl',
  'model',
  'systemPrompt',
  'temperature',
  'maxTokens',
  'timeoutMs',
]);

class CliError extends Error {
  constructor(message, code = 1) {
    super(message);
    this.name = 'CliError';
    this.code = code;
  }
}

function configHome() {
  return process.env.XDG_CONFIG_HOME || path.join(os.homedir(), '.config');
}

function configDir() {
  return path.join(configHome(), 'deepseek-harness');
}

function configFile() {
  return path.join(configDir(), 'config.json');
}

function readConfig() {
  const file = configFile();
  let raw;
  try {
    raw = fs.readFileSync(file, 'utf8');
  } catch (err) {
    if (err.code === 'ENOENT') return {};
    throw new CliError(`No se pudo leer la configuración (${file}): ${err.message}`);
  }

  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new CliError(`Configuración inválida en ${file}: el JSON está malformado.`);
  }

  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new CliError(`Configuración inválida en ${file}: se esperaba un objeto.`);
  }

  // Nunca aceptamos secretos dentro de la configuración.
  for (const key of Object.keys(parsed)) {
    if (SECRET_FIELD.test(key)) {
      throw new CliError(
        `La configuración contiene el campo sospechoso "${key}". ` +
        'Las claves de API deben ir en DEEPSEEK_API_KEY, no en el archivo.'
      );
    }
  }

  return parsed;
}

function writeConfig(cfg) {
  const dir = configDir();
  const file = configFile();
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  try {
    fs.chmodSync(dir, 0o700);
  } catch {
    /* sistemas sin permisos POSIX */
  }

  const tmp = `${file}.tmp-${process.pid}`;
  fs.writeFileSync(tmp, `${JSON.stringify(cfg, null, 2)}\n`, { mode: 0o600 });
  fs.renameSync(tmp, file);
  try {
    fs.chmodSync(file, 0o600);
  } catch {
    /* ignore */
  }
}

function effectiveConfig() {
  const cfg = readConfig();
  return {
    baseUrl: normalizeBaseUrl(process.env.DEEPSEEK_BASE_URL || cfg.baseUrl || DEFAULT_BASE_URL),
    model: process.env.DEEPSEEK_MODEL || cfg.model || DEFAULT_MODEL,
    systemPrompt: typeof cfg.systemPrompt === 'string' ? cfg.systemPrompt : '',
    temperature: cfg.temperature === undefined ? 1 : Number(cfg.temperature),
    maxTokens: cfg.maxTokens === undefined ? DEFAULT_MAX_TOKENS : Number(cfg.maxTokens),
    timeoutMs: cfg.timeoutMs === undefined ? DEFAULT_TIMEOUT_MS : Number(cfg.timeoutMs),
  };
}

function normalizeBaseUrl(raw) {
  let url;
  try {
    url = new URL(String(raw));
  } catch {
    throw new CliError(`URL base inválida: ${raw}`);
  }

  const loopback = ['127.0.0.1', 'localhost', '::1', '[::1]'].includes(url.hostname);
  if (url.protocol !== 'https:' && !(url.protocol === 'http:' && loopback)) {
    throw new CliError(
      'La URL base debe usar HTTPS. Solo se permite HTTP en loopback (127.0.0.1/localhost) para pruebas.'
    );
  }

  url.hash = '';
  url.search = '';
  return url.toString().replace(/\/$/, '');
}

function readApiKey() {
  let key = (process.env.DEEPSEEK_API_KEY || '').trim();

  if (!key) {
    const file = process.env.DEEPSEEK_API_KEY_FILE;
    if (file) {
      try {
        key = fs.readFileSync(file, 'utf8').trim();
      } catch (err) {
        throw new CliError(`No se pudo leer DEEPSEEK_API_KEY_FILE (${file}): ${err.message}`, 3);
      }
      warnIfLoosePermissions(file);
    }
  }

  if (!key) {
    throw new CliError(
      'Falta la clave de API. Define DEEPSEEK_API_KEY en tu entorno\n' +
      'o apunta DEEPSEEK_API_KEY_FILE a un archivo con la clave (permisos 0600).',
      3
    );
  }

  return key;
}

function warnIfLoosePermissions(file) {
  try {
    const mode = fs.statSync(file).mode & 0o777;
    if (mode & 0o077) {
      process.stderr.write(
        `aviso: ${file} es accesible por otros usuarios (permisos ${mode.toString(8)}); ` +
        'usa chmod 600.\n'
      );
    }
  } catch {
    /* ignore */
  }
}

function redact(text) {
  return String(text)
    .replace(/(sk-|Bearer\s+)[A-Za-z0-9._-]+/gi, '$1***')
    .replace(/[A-Za-z0-9_-]{32,}/g, '***')
    .slice(0, 800);
}

function fail(message, code = 1) {
  throw new CliError(message, code);
}

function describeHttpError(status, body) {
  const known = {
    400: 'Solicitud inválida (HTTP 400). Revisa el modelo y los parámetros.',
    401: 'Clave de API inválida o ausente (HTTP 401). Revisa DEEPSEEK_API_KEY.',
    402: 'Saldo insuficiente en tu cuenta de DeepSeek (HTTP 402).',
    403: 'Acceso denegado (HTTP 403).',
    404: 'Recurso no encontrado (HTTP 404). Revisa --model o la URL base.',
    422: 'Parámetros no válidos (HTTP 422).',
    429: 'Límite de peticiones alcanzado (HTTP 429). Reintenta más tarde.',
    500: 'Error interno de DeepSeek (HTTP 500).',
    502: 'Puerta de enlace incorrecta (HTTP 502).',
    503: 'Servicio de DeepSeek no disponible (HTTP 503).',
  };
  const head = known[status] || `Error HTTP ${status}.`;
  const detail = body ? `\n${redact(body)}` : '';
  const error = new CliError(`${head}${detail}`);
  error.status = status;
  return error;
}

/**
 * Petición autenticada a la API de DeepSeek.
 * Devuelve { response, timer }; el llamante debe hacer clearTimeout(timer).
 * `signal` permite cancelar desde fuera (p. ej. si el navegador se desconecta).
 */
async function apiRequest(cfg, key, endpoint, { method = 'GET', body, timeoutMs, signal } = {}) {
  const url = `${cfg.baseUrl}${endpoint}`;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs ?? cfg.timeoutMs);

  let effectiveSignal = controller.signal;
  if (signal) {
    if (typeof AbortSignal.any === 'function') {
      effectiveSignal = AbortSignal.any([controller.signal, signal]);
    } else {
      signal.addEventListener('abort', () => controller.abort(), { once: true });
    }
  }

  const headers = {
    Authorization: `Bearer ${key}`,
    Accept: body && body.stream ? 'text/event-stream' : 'application/json',
  };
  if (body) headers['Content-Type'] = 'application/json';

  let response;
  try {
    response = await fetch(url, {
      method,
      headers,
      body: body ? JSON.stringify(body) : undefined,
      signal: effectiveSignal,
    });
  } catch (err) {
    clearTimeout(timer);
    if (err.name === 'AbortError') {
      if (signal && signal.aborted) fail('Petición cancelada.', 130);
      fail('Tiempo de espera agotado al contactar con DeepSeek.');
    }
    fail(`No se pudo conectar con ${cfg.baseUrl}: ${redact(err.message)}`);
  }

  if (!response.ok) {
    clearTimeout(timer);
    let text = '';
    try {
      text = await response.text();
    } catch {
      /* ignore */
    }
    throw describeHttpError(response.status, text);
  }

  return { response, timer };
}

module.exports = {
  DEFAULT_BASE_URL,
  DEFAULT_MODEL,
  DEFAULT_TIMEOUT_MS,
  DEFAULT_MAX_TOKENS,
  CONFIG_FIELDS,
  SECRET_FIELD,
  CliError,
  configHome,
  configDir,
  configFile,
  readConfig,
  writeConfig,
  effectiveConfig,
  normalizeBaseUrl,
  readApiKey,
  redact,
  fail,
  describeHttpError,
  apiRequest,
};
