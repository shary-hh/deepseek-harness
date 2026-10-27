#!/usr/bin/env node
'use strict';

/*
 * Pruebas de la interfaz web contra un backend DeepSeek mock.
 * No usan red real ni claves reales.
 *
 * Ejecutar: node --test tests/web.test.js
 */

const { test, after } = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');

const ROOT = path.join(__dirname, '..');
const CLI = path.join(ROOT, 'app', 'dist', 'cli.js');

const tempDirs = [];
const processes = [];

after(() => {
  for (const proc of processes) {
    try {
      proc.kill('SIGKILL');
    } catch {
      /* ignore */
    }
  }
  for (const dir of tempDirs) fs.rmSync(dir, { recursive: true, force: true });
});

function newConfigDir() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dh-web-test-'));
  tempDirs.push(dir);
  return dir;
}

function startMockApi() {
  const server = http.createServer((req, res) => {
    let raw = '';
    req.on('data', (chunk) => { raw += chunk; });
    req.on('end', () => {
      if (req.method === 'GET' && req.url === '/models') {
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ data: [{ id: 'deepseek-chat' }, { id: 'deepseek-reasoner' }] }));
        return;
      }

      let body = {};
      try {
        body = JSON.parse(raw || '{}');
      } catch {
        /* ignore */
      }

      if (body.stream) {
        res.writeHead(200, { 'content-type': 'text/event-stream' });
        for (const part of ['Hola', ' desde', ' la web']) {
          res.write(`data: ${JSON.stringify({ choices: [{ delta: { content: part } }] })}\n\n`);
        }
        res.write('data: [DONE]\n\n');
        res.end();
        return;
      }

      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({
        choices: [{ message: { role: 'assistant', content: 'respuesta no-stream' } }],
        model: body.model,
      }));
    });
  });

  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => resolve({ server, port: server.address().port }));
  });
}

function startWeb(configDir, apiPort) {
  const env = {
    ...process.env,
    XDG_CONFIG_HOME: configDir,
    DEEPSEEK_API_KEY: 'test-key-web',
    DEEPSEEK_API_KEY_FILE: '',
    DEEPSEEK_BASE_URL: `http://127.0.0.1:${apiPort}`,
    DEEPSEEK_MODEL: '',
  };

  const proc = spawn(process.execPath, [CLI, 'web', '--port', '0'], {
    cwd: ROOT,
    env,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  processes.push(proc);

  return new Promise((resolve, reject) => {
    let output = '';
    const timer = setTimeout(() => reject(new Error(`timeout arrancando web: ${output}`)), 10000);

    const onData = (chunk) => {
      output += chunk;
      const match = output.match(/http:\/\/127\.0\.0\.1:(\d+)\/\?token=([0-9a-f]{64})/);
      if (match) {
        clearTimeout(timer);
        resolve({
          proc,
          port: Number(match[1]),
          token: match[2],
          origin: `http://127.0.0.1:${match[1]}`,
        });
      }
    };

    proc.stdout.on('data', onData);
    proc.stderr.on('data', onData);
    proc.on('exit', (code) => {
      clearTimeout(timer);
      reject(new Error(`el servidor terminó con código ${code}: ${output}`));
    });
  });
}

async function stopWeb(handle) {
  if (!handle) return;
  await new Promise((resolve) => {
    handle.proc.once('exit', resolve);
    handle.proc.kill('SIGTERM');
    setTimeout(() => {
      try {
        handle.proc.kill('SIGKILL');
      } catch {
        /* ignore */
      }
      resolve();
    }, 2000).unref();
  });
}

async function login(handle) {
  const response = await fetch(`${handle.origin}/?token=${handle.token}`, { redirect: 'manual' });
  assert.equal(response.status, 302);
  const cookie = response.headers.get('set-cookie') || '';
  const match = cookie.match(/dsh_session=([0-9a-f]{64})/);
  assert.ok(match, 'debe establecer la cookie de sesión');
  return match[1];
}

test('la interfaz web exige token y establece cookie HttpOnly', async () => {
  const configDir = newConfigDir();
  const { server, port } = await startMockApi();
  let handle;

  try {
    handle = await startWeb(configDir, port);

    const noToken = await fetch(`${handle.origin}/`);
    assert.equal(noToken.status, 401);

    const response = await fetch(`${handle.origin}/?token=${handle.token}`, { redirect: 'manual' });
    assert.equal(response.status, 302);
    const setCookie = response.headers.get('set-cookie') || '';
    assert.match(setCookie, /HttpOnly/);
    assert.match(setCookie, /SameSite=Strict/);

    const cookie = await login(handle);
    const page = await fetch(`${handle.origin}/`, { headers: { Cookie: `dsh_session=${cookie}` } });
    assert.equal(page.status, 200);
    const html = await page.text();
    assert.match(html, /deepseek-harness/);
    assert.match(page.headers.get('content-security-policy') || '', /script-src 'self'/);
    assert.match(page.headers.get('content-security-policy') || '', /frame-ancestors 'none'/);
    assert.ok(!html.includes('test-key-web'));
  } finally {
    await stopWeb(handle);
    server.close();
  }
});

test('la API exige sesión y no expone la clave', async () => {
  const configDir = newConfigDir();
  const { server, port } = await startMockApi();
  let handle;

  try {
    handle = await startWeb(configDir, port);
    const cookie = await login(handle);

    const unauth = await fetch(`${handle.origin}/api/health`);
    assert.equal(unauth.status, 401);

    const health = await fetch(`${handle.origin}/api/health`, {
      headers: { Cookie: `dsh_session=${cookie}` },
    });
    assert.equal(health.status, 200);
    const data = await health.json();
    assert.equal(data.hasKey, true);
    assert.equal(data.version, JSON.parse(fs.readFileSync(path.join(ROOT, 'app', 'package.json'), 'utf8')).version);

    const text = JSON.stringify(data);
    assert.ok(!text.includes('test-key-web'));

    const js = await fetch(`${handle.origin}/app.js`, {
      headers: { Cookie: `dsh_session=${cookie}` },
    });
    assert.equal(js.status, 200);
    assert.ok(!(await js.text()).includes('test-key-web'));
  } finally {
    await stopWeb(handle);
    server.close();
  }
});

test('chat hace streaming SSE a través del servidor', async () => {
  const configDir = newConfigDir();
  const { server, port } = await startMockApi();
  let handle;

  try {
    handle = await startWeb(configDir, port);
    const cookie = await login(handle);

    const response = await fetch(`${handle.origin}/api/chat`, {
      method: 'POST',
      headers: {
        Cookie: `dsh_session=${cookie}`,
        'Content-Type': 'application/json',
        Origin: handle.origin,
      },
      body: JSON.stringify({ messages: [{ role: 'user', content: 'hola' }], stream: true }),
    });

    assert.equal(response.status, 200);
    assert.match(response.headers.get('content-type') || '', /text\/event-stream/);
    const body = await response.text();
    assert.match(body, /event: delta/);
    assert.match(body, /"text":"Hola"/);
    assert.match(body, /"text":" la web"/);
    assert.match(body, /event: done/);
    assert.ok(!body.includes('test-key-web'));
  } finally {
    await stopWeb(handle);
    server.close();
  }
});

test('chat sin streaming devuelve JSON', async () => {
  const configDir = newConfigDir();
  const { server, port } = await startMockApi();
  let handle;

  try {
    handle = await startWeb(configDir, port);
    const cookie = await login(handle);

    const response = await fetch(`${handle.origin}/api/chat`, {
      method: 'POST',
      headers: {
        Cookie: `dsh_session=${cookie}`,
        'Content-Type': 'application/json',
        Origin: handle.origin,
      },
      body: JSON.stringify({ message: 'hola', stream: false }),
    });
    assert.equal(response.status, 200);
    const data = await response.json();
    assert.equal(data.content, 'respuesta no-stream');
  } finally {
    await stopWeb(handle);
    server.close();
  }
});

test('rechaza peticiones con Origin ajeno (CSRF)', async () => {
  const configDir = newConfigDir();
  const { server, port } = await startMockApi();
  let handle;

  try {
    handle = await startWeb(configDir, port);
    const cookie = await login(handle);

    const response = await fetch(`${handle.origin}/api/chat`, {
      method: 'POST',
      headers: {
        Cookie: `dsh_session=${cookie}`,
        'Content-Type': 'application/json',
        Origin: 'http://evil.example',
      },
      body: JSON.stringify({ message: 'hola' }),
    });
    assert.equal(response.status, 403);
  } finally {
    await stopWeb(handle);
    server.close();
  }
});

test('models devuelve la lista del backend', async () => {
  const configDir = newConfigDir();
  const { server, port } = await startMockApi();
  let handle;

  try {
    handle = await startWeb(configDir, port);
    const cookie = await login(handle);

    const response = await fetch(`${handle.origin}/api/models`, {
      headers: { Cookie: `dsh_session=${cookie}` },
    });
    assert.equal(response.status, 200);
    const data = await response.json();
    assert.deepEqual(data.models, ['deepseek-chat', 'deepseek-reasoner']);
  } finally {
    await stopWeb(handle);
    server.close();
  }
});

test('rechaza escuchar fuera de loopback', async () => {
  const configDir = newConfigDir();
  const result = await new Promise((resolve) => {
    const proc = spawn(process.execPath, [CLI, 'web', '--host', '0.0.0.0', '--port', '0'], {
      cwd: ROOT,
      env: { ...process.env, XDG_CONFIG_HOME: configDir },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stderr = '';
    proc.stderr.on('data', (chunk) => { stderr += chunk; });
    proc.on('exit', (code) => resolve({ code, stderr }));
  });

  assert.notEqual(result.code, 0);
  assert.match(result.stderr, /loopback/);
});
