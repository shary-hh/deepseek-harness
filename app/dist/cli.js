#!/usr/bin/env node
'use strict';

/*
 * deepseek-harness - CLI para la API de DeepSeek.
 *
 * Principios:
 *  - La clave vive SOLO en el entorno (DEEPSEEK_API_KEY) o en un archivo
 *    indicado por DEEPSEEK_API_KEY_FILE. Nunca se escribe en la configuración,
 *    ni se imprime, ni se registra.
 *  - HTTPS obligatorio salvo loopback (para pruebas).
 *  - Sin dependencias externas: usa fetch nativo de Node.js >= 20.
 */

const fs = require('fs');
const path = require('path');

const pkg = require(path.join(__dirname, '..', 'package.json'));

const {
  DEFAULT_BASE_URL,
  DEFAULT_MODEL,
  DEFAULT_TIMEOUT_MS,
  DEFAULT_MAX_TOKENS,
  CONFIG_FIELDS,
  SECRET_FIELD,
  CliError,
  configFile,
  readConfig,
  writeConfig,
  effectiveConfig,
  normalizeBaseUrl,
  readApiKey,
  redact,
  fail,
  apiRequest,
} = require('./core');

const { resolveWorkspace } = require('./workspace');
const { runAgent } = require('./agent');

const VERSION = pkg.version;

// --- Utilidades ------------------------------------------------------------

// Rango recomendado por la guía de DSH: ^22.19.0 || >=24.2.0.
// Node 24.0/24.1 tiene un fallo conocido de salida silenciosa.
function nodeSupported(version = process.versions.node) {
  const [major, minor] = version.split('.').map(Number);
  return (major === 22 && minor >= 19) || (major >= 24 && (major > 24 || minor >= 2));
}

async function readStdin() {
  if (process.stdin.isTTY) return '';
  let data = '';
  for await (const chunk of process.stdin) data += chunk;
  return data.trim();
}

function parseNumber(value, name, { min, max, integer = false }) {
  const num = Number(value);
  if (!Number.isFinite(num)) fail(`--${name} debe ser un número.`, 2);
  if (integer && !Number.isInteger(num)) fail(`--${name} debe ser un entero.`, 2);
  if (min !== undefined && num < min) fail(`--${name} debe ser >= ${min}.`, 2);
  if (max !== undefined && num > max) fail(`--${name} debe ser <= ${max}.`, 2);
  return num;
}

// --- Comandos --------------------------------------------------------------

async function cmdChat(args) {
  const cfg = effectiveConfig();
  const opts = {
    model: cfg.model,
    system: cfg.systemPrompt,
    temperature: cfg.temperature,
    maxTokens: cfg.maxTokens,
    stream: Boolean(process.stdout.isTTY),
    json: false,
    timeoutMs: cfg.timeoutMs,
    workspace: null,
  };
  const words = [];

  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    switch (arg) {
      case '--model':
        opts.model = args[++i] || fail('--model requiere un valor.', 2);
        break;
      case '--system':
        opts.system = args[++i] || fail('--system requiere un valor.', 2);
        break;
      case '--temperature':
        opts.temperature = parseNumber(args[++i], 'temperature', { min: 0, max: 2 });
        break;
      case '--max-tokens':
        opts.maxTokens = parseNumber(args[++i], 'max-tokens', { min: 1, integer: true });
        break;
      case '--timeout':
        opts.timeoutMs = parseNumber(args[++i], 'timeout', { min: 1000, integer: true });
        break;
      case '--stream':
        opts.stream = true;
        break;
      case '--no-stream':
        opts.stream = false;
        break;
      case '--json':
        opts.json = true;
        opts.stream = false;
        break;
      case '--workspace':
        opts.workspace = args[++i] || fail('--workspace requiere un directorio.', 2);
        break;
      case '--':
        words.push(...args.slice(i + 1));
        i = args.length;
        break;
      default:
        if (arg.startsWith('-')) fail(`Opción desconocida: ${arg}`, 2);
        words.push(arg);
    }
  }

  let prompt = words.join(' ').trim();
  if (!prompt) prompt = await readStdin();
  if (!prompt) fail('Falta el mensaje. Uso: deepseek-harness chat "tu pregunta"', 2);

  const key = readApiKey();
  const messages = [];
  if (opts.system) messages.push({ role: 'system', content: opts.system });
  messages.push({ role: 'user', content: prompt });

  if (opts.workspace) {
    const workspace = resolveWorkspace(opts.workspace);
    const result = await runAgent({
      cfg,
      key,
      model: opts.model,
      messages,
      workspace,
      temperature: opts.temperature,
      maxTokens: opts.maxTokens,
      timeoutMs: opts.timeoutMs,
      onEvent: (event) => {
        if (event.type === 'tool') {
          process.stderr.write(`[tool] ${event.name} ${JSON.stringify(event.args)}\n`);
        } else if (event.type === 'tool_result') {
          process.stderr.write(
            `[tool] ${event.ok ? 'ok' : 'error'} ${event.name}: ${event.summary}\n`
          );
        }
      },
    });
    if (opts.json) {
      process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    } else {
      process.stdout.write(`${result.content}\n`);
    }
    return;
  }

  const body = {
    model: opts.model,
    messages,
    stream: opts.stream,
    temperature: opts.temperature,
    max_tokens: opts.maxTokens,
  };

  const { response, timer } = await apiRequest(cfg, key, '/chat/completions', {
    method: 'POST',
    body,
    timeoutMs: opts.timeoutMs,
  });

  try {
    if (opts.stream) {
      await printStream(response);
    } else if (opts.json) {
      const data = await response.json();
      process.stdout.write(`${JSON.stringify(data, null, 2)}\n`);
    } else {
      const data = await response.json();
      const content = data && data.choices && data.choices[0] && data.choices[0].message
        ? data.choices[0].message.content
        : undefined;
      if (typeof content !== 'string') {
        fail('Respuesta inesperada de la API (sin choices[0].message.content).');
      }
      process.stdout.write(`${content}\n`);
    }
  } finally {
    clearTimeout(timer);
  }
}

async function printStream(response) {
  const decoder = new TextDecoder();
  let buffer = '';
  let wrote = false;

  const handleEvent = (event) => {
    for (const line of event.split(/\r?\n/)) {
      if (!line.startsWith('data:')) continue;
      const payload = line.slice(5).trim();
      if (!payload) continue;
      if (payload === '[DONE]') return true;
      let json;
      try {
        json = JSON.parse(payload);
      } catch {
        continue;
      }
      if (json.error) {
        fail(`Error de la API: ${redact(json.error.message || JSON.stringify(json.error))}`);
      }
      const delta = json.choices && json.choices[0] && json.choices[0].delta
        ? json.choices[0].delta.content
        : undefined;
      if (delta) {
        process.stdout.write(delta);
        wrote = true;
      }
    }
    return false;
  };

  for await (const chunk of response.body) {
    buffer += decoder.decode(chunk, { stream: true });
    let match;
    while ((match = buffer.match(/\r?\n\r?\n/)) !== null) {
      const index = match.index;
      const event = buffer.slice(0, index);
      buffer = buffer.slice(index + match[0].length);
      if (handleEvent(event)) {
        if (wrote) process.stdout.write('\n');
        return;
      }
    }
  }

  buffer += decoder.decode();
  if (buffer.trim()) handleEvent(buffer);
  if (wrote) process.stdout.write('\n');
}

async function cmdWeb(args) {
  const opts = { port: 8787, host: '127.0.0.1', open: false, workspace: null };

  for (let i = 0; i < args.length; i += 1) {
    switch (args[i]) {
      case '--port':
        opts.port = parseNumber(args[++i], 'port', { min: 0, max: 65535, integer: true });
        break;
      case '--host':
        opts.host = args[++i] || fail('--host requiere un valor.', 2);
        break;
      case '--open':
        opts.open = true;
        break;
      case '--no-open':
        opts.open = false;
        break;
      case '--workspace':
        opts.workspace = args[++i] || fail('--workspace requiere un directorio.', 2);
        break;
      default:
        fail(`Opción desconocida: ${args[i]}`, 2);
    }
  }

  const { runWeb } = require('./web-server');
  await runWeb(opts);
}

async function cmdModels(args) {
  const cfg = effectiveConfig();
  const json = args.includes('--json');
  const key = readApiKey();
  const { response, timer } = await apiRequest(cfg, key, '/models');
  try {
    const data = await response.json();
    if (json) {
      process.stdout.write(`${JSON.stringify(data, null, 2)}\n`);
      return;
    }
    const models = Array.isArray(data.data) ? data.data : [];
    if (!models.length) {
      process.stdout.write('No se devolvieron modelos.\n');
      return;
    }
    for (const model of models) {
      const id = model && model.id ? model.id : '(sin id)';
      const owner = model && model.owned_by ? `  [${model.owned_by}]` : '';
      process.stdout.write(`${id}${owner}\n`);
    }
  } finally {
    clearTimeout(timer);
  }
}

async function cmdDoctor(args) {
  const cfg = effectiveConfig();
  const ping = args.includes('--ping');

  const wsIndex = args.indexOf('--workspace');
  let workspace = null;
  if (wsIndex !== -1) {
    workspace = resolveWorkspace(args[wsIndex + 1] || fail('--workspace requiere un directorio.', 2));
  }

  let key = '';

  try {
    key = readApiKey();
  } catch {
    key = '';
  }

  const file = configFile();
  let perms = 'no existe';
  try {
    perms = (fs.statSync(file).mode & 0o777).toString(8).padStart(3, '0');
  } catch {
    /* no existe */
  }

  const keySource = process.env.DEEPSEEK_API_KEY
    ? 'DEEPSEEK_API_KEY'
    : process.env.DEEPSEEK_API_KEY_FILE
      ? 'DEEPSEEK_API_KEY_FILE'
      : 'ninguna';
  const proxySet = Boolean(
    process.env.HTTPS_PROXY || process.env.https_proxy ||
    process.env.HTTP_PROXY || process.env.http_proxy
  );

  process.stdout.write('Entorno de deepseek-harness\n');
  process.stdout.write(`  versión:           ${VERSION}\n`);
  process.stdout.write(`  node:              ${process.version} (${nodeSupported() ? 'soportado' : 'NO soportado'})\n`);
  process.stdout.write(`  plataforma:        ${process.platform}/${process.arch}\n`);
  process.stdout.write(`  URL base:          ${cfg.baseUrl}\n`);
  process.stdout.write(`  modelo:            ${cfg.model}\n`);
  process.stdout.write(`  configuración:     ${file} (permisos ${perms})\n`);
  process.stdout.write(`  workspace:         ${workspace || 'no configurado (sin herramientas)'}\n`);
  process.stdout.write(
    `  DEEPSEEK_API_KEY:  ${key ? `definida (${key.length} caracteres, valor oculto; origen: ${keySource})` : 'no definida'}\n`
  );
  process.stdout.write(`  proxy:             ${proxySet ? 'definido (valor oculto)' : 'no definido'}\n`);

  if (!key) {
    process.stderr.write('\nDefine DEEPSEEK_API_KEY o DEEPSEEK_API_KEY_FILE para usar chat/models.\n');
    process.exitCode = 1;
    return;
  }

  if (ping) {
    try {
      const { response, timer } = await apiRequest(cfg, key, '/models');
      try {
        const data = await response.json();
        const count = Array.isArray(data.data) ? data.data.length : 0;
        process.stdout.write(`  API:               OK (${count} modelos disponibles)\n`);
      } finally {
        clearTimeout(timer);
      }
    } catch (err) {
      process.stdout.write(`  API:               error (${err.message.split('\n')[0]})\n`);
      process.exitCode = 1;
    }
  } else {
    process.stdout.write('  API:               no comprobada (usa --ping)\n');
  }
}

function cmdConfig(args) {
  const sub = args[0] || 'show';

  if (sub === 'path') {
    process.stdout.write(`${configFile()}\n`);
    return;
  }

  if (sub === 'show') {
    const cfg = readConfig();
    const shown = {};
    for (const key of CONFIG_FIELDS) {
      if (cfg[key] !== undefined) shown[key] = cfg[key];
    }
    process.stdout.write(`${JSON.stringify(shown, null, 2)}\n`);
    return;
  }

  if (sub === 'init') {
    const force = args.includes('--force');
    const file = configFile();
    if (fs.existsSync(file) && !force) {
      fail(`Ya existe ${file}. Usa --force para sobrescribirlo.`);
    }
    writeConfig({
      baseUrl: DEFAULT_BASE_URL,
      model: DEFAULT_MODEL,
      temperature: 1,
      maxTokens: DEFAULT_MAX_TOKENS,
      timeoutMs: DEFAULT_TIMEOUT_MS,
    });
    process.stdout.write(`Configuración creada: ${file}\n`);
    return;
  }

  if (sub === 'set') {
    const [, key, ...rest] = args;
    const value = rest.join(' ');
    if (!key || !value) fail('Uso: deepseek-harness config set <campo> <valor>', 2);
    if (!CONFIG_FIELDS.has(key)) {
      fail(`Campo no permitido: ${key}. Válidos: ${[...CONFIG_FIELDS].join(', ')}`, 2);
    }
    if (SECRET_FIELD.test(key)) {
      fail('Las claves de API no se guardan en la configuración. Usa DEEPSEEK_API_KEY.', 2);
    }

    const cfg = readConfig();
    if (['temperature', 'maxTokens', 'timeoutMs'].includes(key)) {
      cfg[key] = parseNumber(value, key, { min: 0 });
    } else if (key === 'baseUrl') {
      cfg[key] = normalizeBaseUrl(value);
    } else {
      cfg[key] = value;
    }
    writeConfig(cfg);
    process.stdout.write(`${key} = ${cfg[key]}\n`);
    return;
  }

  if (sub === 'unset') {
    const key = args[1];
    if (!key) fail('Uso: deepseek-harness config unset <campo>', 2);
    const cfg = readConfig();
    delete cfg[key];
    writeConfig(cfg);
    process.stdout.write(`${key} eliminado\n`);
    return;
  }

  fail(`Subcomando de config desconocido: ${sub}`, 2);
}

// --- Ayuda y entrada -------------------------------------------------------

function printHelp() {
  process.stdout.write(`deepseek-harness ${VERSION}

Uso:
  deepseek-harness <comando> [opciones]

Comandos:
  chat [mensaje]        Conversa con la API de DeepSeek
  models                Lista los modelos disponibles
  doctor [--ping] [--workspace <dir>]
                        Comprueba entorno, clave y conectividad
  config [show|path|init|set|unset]
                        Gestiona la configuración (nunca guarda claves)
  web [--port 8787] [--open]
                        Interfaz gráfica local (solo loopback)

Opciones de chat:
  --model <id>          Modelo (por defecto: ${DEFAULT_MODEL})
  --system <texto>      Prompt de sistema
  --temperature <n>     0..2 (por defecto: 1)
  --max-tokens <n>      Tokens máximos de la respuesta
  --timeout <ms>        Tiempo máximo de espera
  --stream / --no-stream
                        Forzar streaming o desactivarlo
  --json                Imprime la respuesta JSON completa
  --workspace <dir>     Habilita herramientas de solo lectura en ese directorio

Opciones de web:
  --port <n>            Puerto local (por defecto: 8787; 0 = aleatorio)
  --host <host>         Solo loopback (127.0.0.1, ::1, localhost)
  --open                Abre el navegador automáticamente
  --workspace <dir>     Habilita herramientas de solo lectura en ese directorio

Globales:
  -h, --help            Muestra esta ayuda
  -v, --version         Muestra la versión

Entorno:
  DEEPSEEK_API_KEY      Clave de API (obligatoria; nunca se imprime)
  DEEPSEEK_API_KEY_FILE Archivo con la clave (permisos 0600)
  DEEPSEEK_BASE_URL     URL base (por defecto: ${DEFAULT_BASE_URL})
  DEEPSEEK_MODEL        Modelo por defecto

Ejemplos:
  deepseek-harness chat "Explica qué es un AppImage"
  echo "resume este texto" | deepseek-harness chat
  deepseek-harness chat --model deepseek-reasoner "razona esto"
  deepseek-harness models
  deepseek-harness doctor --ping
`);
}

async function main(argv) {
  const [command, ...rest] = argv;

  if (!command || command === 'help' || command === '-h' || command === '--help') {
    printHelp();
    return;
  }
  if (command === '-v' || command === '--version' || command === 'version') {
    process.stdout.write(`${VERSION}\n`);
    return;
  }

  switch (command) {
    case 'chat':
      await cmdChat(rest);
      break;
    case 'models':
      await cmdModels(rest);
      break;
    case 'doctor':
      await cmdDoctor(rest);
      break;
    case 'config':
      cmdConfig(rest);
      break;
    case 'web':
      await cmdWeb(rest);
      break;
    default:
      fail(`Comando desconocido: ${command}. Usa --help.`, 2);
  }
}

if (!nodeSupported()) {
  process.stderr.write(
    `Node.js ${process.version} no está soportado.\n` +
    'Usa ^22.19.0 o >=24.2.0 (evita 24.0/24.1 por un fallo conocido de salida silenciosa).\n'
  );
  process.exit(1);
}

process.on('SIGINT', () => {
  process.stderr.write('\ninterrumpido\n');
  process.exit(130);
});

main(process.argv.slice(2)).catch((err) => {
  if (err instanceof CliError) {
    process.stderr.write(`error: ${err.message}\n`);
    process.exit(err.code);
  }
  process.stderr.write(`error: ${redact(err && err.message ? err.message : String(err))}\n`);
  process.exit(1);
});
