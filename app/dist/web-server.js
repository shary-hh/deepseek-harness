#!/usr/bin/env node
'use strict';

/*
 * Interfaz web local de deepseek-harness.
 *
 * Seguridad:
 *  - Escucha SOLO en loopback (127.0.0.1 / ::1).
 *  - Token de sesión aleatorio en la URL inicial; cookie HttpOnly + SameSite=Strict.
 *  - Comprobación de Host (anti DNS-rebinding) y Origin (anti CSRF).
 *  - La clave de API nunca llega al navegador: todas las llamadas salen del servidor.
 *  - CSP estricta, sin scripts en línea.
 *  - Límite de tamaño de cuerpo y de streams concurrentes.
 */

const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { spawn } = require('child_process');

const {
  CliError,
  effectiveConfig,
  readApiKey,
  apiRequest,
  redact,
} = require('./core');

const { resolveWorkspace } = require('./workspace');
const { runAgent } = require('./agent');

const pkg = require(path.join(__dirname, '..', 'package.json'));

const WEB_DIR = path.join(__dirname, 'web');
const TOKEN_RE = /^[0-9a-f]{64}$/;
const COOKIE_NAME = 'dsh_session';
const MAX_BODY = 256 * 1024;
const MAX_STREAMS = 4;
const LOOPBACK = new Set(['127.0.0.1', 'localhost', '::1', '[::1]']);

function isLoopback(host) {
  return LOOPBACK.has(host);
}

function hostnameOf(hostHeader) {
  if (!hostHeader) return '';
  if (hostHeader.startsWith('[')) {
    const end = hostHeader.indexOf(']');
    return end === -1 ? hostHeader : hostHeader.slice(0, end + 1);
  }
  return hostHeader.split(':')[0];
}

function setSecurityHeaders(res) {
  res.setHeader(
    'Content-Security-Policy',
    "default-src 'none'; style-src 'self'; script-src 'self'; connect-src 'self'; " +
    "img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
  );
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('Referrer-Policy', 'no-referrer');
  res.setHeader('Cache-Control', 'no-store');
}

function sendJson(res, status, payload) {
  const data = Buffer.from(JSON.stringify(payload));
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': data.length,
  });
  res.end(data);
}

function sendText(res, status, text) {
  const data = Buffer.from(`${text}\n`);
  res.writeHead(status, {
    'Content-Type': 'text/plain; charset=utf-8',
    'Content-Length': data.length,
  });
  res.end(data);
}

function readBody(req, limit = MAX_BODY) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > limit) {
        reject(new CliError('Cuerpo de la petición demasiado grande.', 413));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

function validateMessages(body) {
  if (typeof body.message === 'string' && body.message.trim()) {
    return [{ role: 'user', content: body.message.trim() }];
  }
  if (!Array.isArray(body.messages) || body.messages.length === 0) {
    throw new CliError('Falta el mensaje.', 400);
  }
  if (body.messages.length > 60) {
    throw new CliError('Demasiados mensajes en la conversación (máximo 60).', 400);
  }

  let total = 0;
  return body.messages.map((message) => {
    if (!message || typeof message !== 'object') {
      throw new CliError('Mensaje inválido.', 400);
    }
    const role = String(message.role || '');
    if (!['system', 'user', 'assistant'].includes(role)) {
      throw new CliError(`Rol no permitido: ${redact(role)}`, 400);
    }
    const content = typeof message.content === 'string' ? message.content : '';
    if (!content.trim()) throw new CliError('Mensaje vacío.', 400);
    total += content.length;
    if (total > 128 * 1024) {
      throw new CliError('La conversación es demasiado larga.', 413);
    }
    return { role, content };
  });
}

function numberInRange(value, fallback, { min, max, integer = false }) {
  if (value === undefined || value === null || value === '') return fallback;
  const num = Number(value);
  if (!Number.isFinite(num)) throw new CliError('Parámetro numérico inválido.', 400);
  if (integer && !Number.isInteger(num)) throw new CliError('Se esperaba un entero.', 400);
  if (num < min || num > max) throw new CliError(`Valor fuera de rango (${min}..${max}).`, 400);
  return num;
}

function errorStatus(err) {
  if (err && err.status) return err.status;
  if (err instanceof CliError && err.code === 3) return 400;
  if (err instanceof CliError && err.code === 413) return 413;
  return 502;
}

/**
 * Arranca el servidor. Devuelve { server, url, token }.
 */
async function startWeb({ host = '127.0.0.1', port = 8787, open = false, workspace = null } = {}) {
  if (!isLoopback(host)) {
    throw new CliError(
      `Por seguridad, la interfaz web solo puede escuchar en loopback (127.0.0.1/::1), no en "${host}".`
    );
  }

  const workspaceRoot = resolveWorkspace(workspace);
  const token = crypto.randomBytes(32).toString('hex');
  const tokenBuffer = Buffer.from(token);
  let activeStreams = 0;

  function hasSession(req) {
    const cookie = req.headers.cookie || '';
    const match = cookie.match(new RegExp(`(?:^|;\\s*)${COOKIE_NAME}=([0-9a-f]{64})(?:;|$)`));
    if (!match) return false;
    const got = Buffer.from(match[1]);
    return got.length === tokenBuffer.length && crypto.timingSafeEqual(got, tokenBuffer);
  }

  function originAllowed(req) {
    const origin = req.headers.origin;
    if (!origin) return true; // clientes locales sin navegador
    return origin === `http://${req.headers.host}`;
  }

  async function handleChat(req, res) {
    if (!originAllowed(req)) {
      sendJson(res, 403, { error: 'Origen no permitido.' });
      return;
    }
    if (!String(req.headers['content-type'] || '').startsWith('application/json')) {
      sendJson(res, 415, { error: 'Content-Type debe ser application/json.' });
      return;
    }

    let body;
    try {
      body = JSON.parse(await readBody(req));
    } catch (err) {
      sendJson(res, err.code === 413 ? 413 : 400, { error: 'JSON inválido.' });
      return;
    }
    if (!body || typeof body !== 'object' || Array.isArray(body)) {
      sendJson(res, 400, { error: 'Cuerpo inválido.' });
      return;
    }

    const cfg = effectiveConfig();
    const model = String(body.model || cfg.model);
    if (!/^[A-Za-z0-9._:-]{1,80}$/.test(model)) {
      sendJson(res, 400, { error: 'Nombre de modelo inválido.' });
      return;
    }

    let messages;
    try {
      messages = validateMessages(body);
    } catch (err) {
      sendJson(res, errorStatus(err) === 502 ? 400 : errorStatus(err), { error: err.message });
      return;
    }

    let key;
    try {
      key = readApiKey();
    } catch (err) {
      sendJson(res, 400, { error: err.message });
      return;
    }

    const payload = {
      model,
      messages,
      temperature: numberInRange(body.temperature, cfg.temperature, { min: 0, max: 2 }),
      max_tokens: numberInRange(body.maxTokens, cfg.maxTokens, { min: 1, max: 8192, integer: true }),
    };

    if (workspaceRoot) {
      await handleWorkspaceChat(req, res, { body, payload, cfg, key });
      return;
    }

    if (body.stream === false) {
      try {
        const { response, timer } = await apiRequest(cfg, key, '/chat/completions', {
          method: 'POST',
          body: { ...payload, stream: false },
        });
        let data;
        try {
          data = await response.json();
        } finally {
          clearTimeout(timer);
        }
        const content = data && data.choices && data.choices[0] && data.choices[0].message
          ? data.choices[0].message.content || ''
          : '';
        sendJson(res, 200, { content, model: data.model, usage: data.usage || null });
      } catch (err) {
        sendJson(res, errorStatus(err), { error: redact(err.message) });
      }
      return;
    }

    if (activeStreams >= MAX_STREAMS) {
      sendJson(res, 429, { error: 'Demasiadas peticiones simultáneas. Espera a que termine una.' });
      return;
    }
    activeStreams += 1;

    const controller = new AbortController();
    res.on('close', () => {
      if (!res.writableEnded) controller.abort();
    });

    res.writeHead(200, {
      'Content-Type': 'text/event-stream; charset=utf-8',
      Connection: 'keep-alive',
      'X-Accel-Buffering': 'no',
    });

    const sendEvent = (name, payload) => {
      if (res.writableEnded || res.destroyed) return;
      res.write(`event: ${name}\ndata: ${JSON.stringify(payload)}\n\n`);
    };

    let timer;
    try {
      const started = await apiRequest(cfg, key, '/chat/completions', {
        method: 'POST',
        body: { ...payload, stream: true },
        signal: controller.signal,
      });
      timer = started.timer;
      await forwardStream(started.response, sendEvent);
      sendEvent('done', {});
    } catch (err) {
      if (!controller.signal.aborted) {
        sendEvent('error', { message: redact(err.message) });
      }
    } finally {
      if (timer) clearTimeout(timer);
      activeStreams -= 1;
      if (!res.writableEnded) res.end();
    }
  }

  async function forwardStream(response, sendEvent) {
    const decoder = new TextDecoder();
    let buffer = '';
    let finished = false;

    const handleEvent = (event) => {
      for (const line of event.split(/\r?\n/)) {
        if (!line.startsWith('data:')) continue;
        const raw = line.slice(5).trim();
        if (!raw) continue;
        if (raw === '[DONE]') {
          finished = true;
          return;
        }
        let json;
        try {
          json = JSON.parse(raw);
        } catch {
          continue;
        }
        if (json.error) {
          throw new CliError(redact(json.error.message || JSON.stringify(json.error)));
        }
        const delta = json.choices && json.choices[0] && json.choices[0].delta
          ? json.choices[0].delta.content
          : undefined;
        if (delta) sendEvent('delta', { text: delta });
      }
    };

    for await (const chunk of response.body) {
      buffer += decoder.decode(chunk, { stream: true });
      let match;
      while ((match = buffer.match(/\r?\n\r?\n/)) !== null) {
        const index = match.index;
        const event = buffer.slice(0, index);
        buffer = buffer.slice(index + match[0].length);
        handleEvent(event);
        if (finished) return;
      }
    }
    buffer += decoder.decode();
    if (buffer.trim()) handleEvent(buffer);
  }

  async function handleWorkspaceChat(req, res, { body, payload, cfg, key }) {
    if (body.stream === false) {
      const events = [];
      try {
        const result = await runAgent({
          cfg,
          key,
          model: payload.model,
          messages: payload.messages,
          workspace: workspaceRoot,
          temperature: payload.temperature,
          maxTokens: payload.max_tokens,
          timeoutMs: cfg.timeoutMs,
          onEvent: (event) => events.push(event),
        });
        sendJson(res, 200, {
          content: result.content,
          steps: result.steps,
          tools: events,
          usage: result.usage,
        });
      } catch (err) {
        sendJson(res, errorStatus(err), { error: redact(err.message) });
      }
      return;
    }

    if (activeStreams >= MAX_STREAMS) {
      sendJson(res, 429, { error: 'Demasiadas peticiones simultáneas. Espera a que termine una.' });
      return;
    }
    activeStreams += 1;

    const controller = new AbortController();
    res.on('close', () => {
      if (!res.writableEnded) controller.abort();
    });

    res.writeHead(200, {
      'Content-Type': 'text/event-stream; charset=utf-8',
      Connection: 'keep-alive',
      'X-Accel-Buffering': 'no',
    });

    const sendEvent = (name, eventPayload) => {
      if (res.writableEnded || res.destroyed) return;
      res.write(`event: ${name}\ndata: ${JSON.stringify(eventPayload)}\n\n`);
    };

    try {
      const result = await runAgent({
        cfg,
        key,
        model: payload.model,
        messages: payload.messages,
        workspace: workspaceRoot,
        temperature: payload.temperature,
        maxTokens: payload.max_tokens,
        timeoutMs: cfg.timeoutMs,
        signal: controller.signal,
        onEvent: (event) => sendEvent(event.type, event),
      });
      sendEvent('delta', { text: result.content });
      sendEvent('done', { steps: result.steps });
    } catch (err) {
      if (!controller.signal.aborted) {
        sendEvent('error', { message: redact(err.message) });
      }
    } finally {
      activeStreams -= 1;
      if (!res.writableEnded) res.end();
    }
  }

  async function handle(req, res) {
    setSecurityHeaders(res);

    // Anti DNS-rebinding: el Host debe ser loopback.
    if (!isLoopback(hostnameOf(req.headers.host))) {
      sendText(res, 400, 'Host no permitido.');
      return;
    }

    const url = new URL(req.url, `http://${req.headers.host || host}`);
    const route = url.pathname;

    if (route === '/') {
      if (req.method !== 'GET') {
        sendText(res, 405, 'Método no permitido.');
        return;
      }
      const supplied = url.searchParams.get('token');
      if (supplied !== null) {
        if (!TOKEN_RE.test(supplied) || !crypto.timingSafeEqual(Buffer.from(supplied), tokenBuffer)) {
          sendText(res, 403, 'Token inválido.');
          return;
        }
        res.setHeader('Set-Cookie', `${COOKIE_NAME}=${token}; HttpOnly; SameSite=Strict; Path=/; Max-Age=86400`);
        res.writeHead(302, { Location: '/' });
        res.end();
        return;
      }
      if (!hasSession(req)) {
        sendText(res, 401, 'Abre la URL con token que se mostró al arrancar la interfaz.');
        return;
      }
      const html = fs.readFileSync(path.join(WEB_DIR, 'index.html'));
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Content-Length': html.length });
      res.end(html);
      return;
    }

    if (route === '/app.js' || route === '/app.css') {
      if (!hasSession(req)) {
        sendText(res, 401, 'No autorizado.');
        return;
      }
      const file = route === '/app.js' ? 'app.js' : 'app.css';
      const data = fs.readFileSync(path.join(WEB_DIR, file));
      res.writeHead(200, {
        'Content-Type': file.endsWith('.js') ? 'text/javascript; charset=utf-8' : 'text/css; charset=utf-8',
        'Content-Length': data.length,
      });
      res.end(data);
      return;
    }

    if (route === '/favicon.ico') {
      res.writeHead(204);
      res.end();
      return;
    }

    if (!hasSession(req)) {
      sendJson(res, 401, { error: 'No autorizado.' });
      return;
    }

    if (route === '/api/health' && req.method === 'GET') {
      const cfg = effectiveConfig();
      let hasKey = false;
      try {
        readApiKey();
        hasKey = true;
      } catch {
        hasKey = false;
      }
      sendJson(res, 200, {
        version: pkg.version,
        node: process.version,
        platform: `${process.platform}/${process.arch}`,
        model: cfg.model,
        baseUrl: cfg.baseUrl,
        hasKey,
        workspace: workspaceRoot,
        tools: Boolean(workspaceRoot),
      });
      return;
    }

    if (route === '/api/models' && req.method === 'GET') {
      try {
        const cfg = effectiveConfig();
        const key = readApiKey();
        const { response, timer } = await apiRequest(cfg, key, '/models');
        let data;
        try {
          data = await response.json();
        } finally {
          clearTimeout(timer);
        }
        const models = Array.isArray(data.data) ? data.data.map((m) => String(m.id)) : [];
        sendJson(res, 200, { models });
      } catch (err) {
        sendJson(res, errorStatus(err), { error: redact(err.message) });
      }
      return;
    }

    if (route === '/api/chat' && req.method === 'POST') {
      await handleChat(req, res);
      return;
    }

    sendJson(res, 404, { error: 'No encontrado.' });
  }

  const server = http.createServer((req, res) => {
    handle(req, res).catch((err) => {
      if (res.headersSent) {
        if (!res.writableEnded) res.end();
        return;
      }
      sendJson(res, 500, { error: redact(err.message) });
    });
  });

  server.on('clientError', (err, socket) => {
    if (socket.writable) socket.end('HTTP/1.1 400 Bad Request\r\n\r\n');
  });

  await new Promise((resolve, reject) => {
    const onError = (err) => {
      server.removeListener('listening', onListening);
      if (err.code === 'EADDRINUSE') {
        reject(new CliError(
          `El puerto ${port} ya está en uso. Usa --port 0 para elegir uno libre o --port <otro>.`
        ));
        return;
      }
      if (err.code === 'EACCES') {
        reject(new CliError(`Sin permiso para escuchar en el puerto ${port}. Usa un puerto >= 1024.`));
        return;
      }
      reject(new CliError(`No se pudo escuchar en ${host}:${port}: ${err.message}`));
    };
    const onListening = () => {
      server.removeListener('error', onError);
      resolve();
    };
    server.once('error', onError);
    server.once('listening', onListening);
    server.listen(port, host);
  });

  const address = server.address();
  const actualPort = address.port;
  const displayHost = host.includes(':') ? `[${host}]` : host;
  const url = `http://${displayHost}:${actualPort}/?token=${token}`;

  return { server, url, token, open, workspace: workspaceRoot };
}

function openBrowser(url) {
  const platform = process.platform;
  const command = platform === 'darwin' ? 'open' : platform === 'win32' ? 'cmd' : 'xdg-open';
  const args = platform === 'win32' ? ['/c', 'start', '', url] : [url];
  try {
    const child = spawn(command, args, { detached: true, stdio: 'ignore' });
    child.on('error', () => {});
    child.unref();
  } catch {
    /* si no hay navegador, el usuario abre la URL a mano */
  }
}

/**
 * Arranca la interfaz y espera hasta que se cierre (Ctrl+C).
 */
async function runWeb(options = {}) {
  const { server, url, open, workspace } = await startWeb(options);

  process.stdout.write(`Interfaz web: ${url}\n`);
  if (workspace) {
    process.stdout.write(`Workspace (solo lectura): ${workspace}\n`);
  }
  process.stdout.write('Pulsa Ctrl+C para detener.\n');
  if (open) openBrowser(url);

  await new Promise((resolve) => {
    let closing = false;
    const shutdown = () => {
      if (closing) return;
      closing = true;
      server.close(() => resolve());
      setTimeout(() => process.exit(0), 2000).unref();
    };
    process.once('SIGINT', shutdown);
    process.once('SIGTERM', shutdown);
    server.once('close', resolve);
  });
}

module.exports = { startWeb, runWeb, isLoopback };
