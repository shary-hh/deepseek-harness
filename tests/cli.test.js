#!/usr/bin/env node
'use strict';

/*
 * Pruebas de la CLI contra un servidor HTTP local.
 * Nunca usan la red real ni claves reales.
 *
 * Ejecutar: node --test tests/cli.test.js
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
after(() => {
  for (const dir of tempDirs) fs.rmSync(dir, { recursive: true, force: true });
});

function newConfigDir() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dh-cli-test-'));
  tempDirs.push(dir);
  return dir;
}

function baseEnv(configDir) {
  return {
    ...process.env,
    XDG_CONFIG_HOME: configDir,
    DEEPSEEK_API_KEY: '',
    DEEPSEEK_API_KEY_FILE: '',
    DEEPSEEK_BASE_URL: '',
    DEEPSEEK_MODEL: '',
  };
}

function run(args, { env = {}, input = null } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [CLI, ...args], {
      cwd: ROOT,
      env,
      stdio: ['pipe', 'pipe', 'pipe'],
    });

    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (chunk) => { stdout += chunk; });
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    child.on('error', reject);
    child.on('close', (code) => resolve({ code, stdout, stderr }));

    if (input === null) child.stdin.end();
    else child.stdin.end(input);
  });
}

async function withServer(handler, fn) {
  const server = http.createServer(handler);
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();
  try {
    return await fn(port);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
}

function jsonHandler(requests, payload, status = 200) {
  return (req, res) => {
    let raw = '';
    req.on('data', (chunk) => { raw += chunk; });
    req.on('end', () => {
      requests.push({
        url: req.url,
        method: req.method,
        headers: req.headers,
        body: raw ? JSON.parse(raw) : null,
      });
      res.writeHead(status, { 'content-type': 'application/json' });
      res.end(JSON.stringify(payload));
    });
  };
}

test('--version responde con la versión del paquete', async () => {
  const cfg = newConfigDir();
  const result = await run(['--version'], { env: baseEnv(cfg) });
  const pkg = JSON.parse(fs.readFileSync(path.join(ROOT, 'app', 'package.json'), 'utf8'));
  assert.equal(result.code, 0);
  assert.equal(result.stdout.trim(), pkg.version);
});

test('la ayuda documenta los comandos principales', async () => {
  const cfg = newConfigDir();
  const result = await run(['--help'], { env: baseEnv(cfg) });
  assert.equal(result.code, 0);
  for (const command of ['chat', 'models', 'doctor', 'config']) {
    assert.match(result.stdout, new RegExp(command));
  }
});

test('doctor no imprime la clave, aunque esté definida', async () => {
  const cfg = newConfigDir();
  const secret = 'clave-super-secreta-123';
  const result = await run(['doctor'], {
    env: { ...baseEnv(cfg), DEEPSEEK_API_KEY: secret },
  });

  assert.equal(result.code, 0);
  assert.match(result.stdout, /definida \(.*valor oculto/);
  assert.ok(!result.stdout.includes(secret), 'stdout no debe contener la clave');
  assert.ok(!result.stderr.includes(secret), 'stderr no debe contener la clave');
});

test('doctor falla cuando no hay clave', async () => {
  const cfg = newConfigDir();
  const result = await run(['doctor'], { env: baseEnv(cfg) });
  assert.equal(result.code, 1);
  assert.match(result.stdout, /no definida/);
});

test('chat envía el mensaje y la cabecera Authorization correctos', async () => {
  const cfg = newConfigDir();
  const requests = [];

  await withServer(
    jsonHandler(requests, { choices: [{ message: { role: 'assistant', content: 'respuesta mock' } }] }),
    async (port) => {
      const result = await run(['chat', 'hola'], {
        env: {
          ...baseEnv(cfg),
          DEEPSEEK_API_KEY: 'test-key',
          DEEPSEEK_BASE_URL: `http://127.0.0.1:${port}`,
        },
      });
      assert.equal(result.code, 0);
      assert.equal(result.stdout.trim(), 'respuesta mock');
    }
  );

  assert.equal(requests.length, 1);
  assert.equal(requests[0].url, '/chat/completions');
  assert.equal(requests[0].headers.authorization, 'Bearer test-key');
  assert.equal(requests[0].body.model, 'deepseek-chat');
  assert.equal(requests[0].body.stream, false);
  assert.deepEqual(requests[0].body.messages, [{ role: 'user', content: 'hola' }]);
});

test('chat lee el prompt desde stdin', async () => {
  const cfg = newConfigDir();
  const requests = [];

  await withServer(
    jsonHandler(requests, { choices: [{ message: { content: 'ok' } }] }),
    async (port) => {
      const result = await run(['chat'], {
        input: 'desde stdin\n',
        env: {
          ...baseEnv(cfg),
          DEEPSEEK_API_KEY: 'test-key',
          DEEPSEEK_BASE_URL: `http://127.0.0.1:${port}`,
        },
      });
      assert.equal(result.code, 0);
    }
  );

  assert.equal(requests[0].body.messages.at(-1).content, 'desde stdin');
});

test('chat --stream ensambla los eventos SSE', async () => {
  const cfg = newConfigDir();
  const requests = [];

  await withServer(
    (req, res) => {
      let raw = '';
      req.on('data', (chunk) => { raw += chunk; });
      req.on('end', () => {
        requests.push({ body: JSON.parse(raw) });
        res.writeHead(200, { 'content-type': 'text/event-stream' });
        res.write('data: {"choices":[{"delta":{"content":"Hola"}}]}\n\n');
        res.write('data: {"choices":[{"delta":{"content":" mundo"}}]}\n\n');
        res.write('data: [DONE]\n\n');
        res.end();
      });
    },
    async (port) => {
      const result = await run(['chat', '--stream', 'hola'], {
        env: {
          ...baseEnv(cfg),
          DEEPSEEK_API_KEY: 'test-key',
          DEEPSEEK_BASE_URL: `http://127.0.0.1:${port}`,
        },
      });
      assert.equal(result.code, 0);
      assert.equal(result.stdout.trim(), 'Hola mundo');
    }
  );

  assert.equal(requests[0].body.stream, true);
});

test('chat --json imprime la respuesta completa', async () => {
  const cfg = newConfigDir();
  const payload = { id: 'abc', choices: [{ message: { content: 'hola' } }] };

  await withServer(jsonHandler([], payload), async (port) => {
    const result = await run(['chat', '--json', 'hola'], {
      env: {
        ...baseEnv(cfg),
        DEEPSEEK_API_KEY: 'test-key',
        DEEPSEEK_BASE_URL: `http://127.0.0.1:${port}`,
      },
    });
    assert.equal(result.code, 0);
    assert.deepEqual(JSON.parse(result.stdout), payload);
  });
});

test('un 401 muestra un error claro y no filtra la clave', async () => {
  const cfg = newConfigDir();
  const secret = 'test-key-que-no-debe-salir';

  await withServer(
    jsonHandler([], { error: { message: 'Authentication Fails' } }, 401),
    async (port) => {
      const result = await run(['chat', 'hola'], {
        env: {
          ...baseEnv(cfg),
          DEEPSEEK_API_KEY: secret,
          DEEPSEEK_BASE_URL: `http://127.0.0.1:${port}`,
        },
      });
      assert.equal(result.code, 1);
      assert.match(result.stderr, /401/);
      assert.ok(!result.stdout.includes(secret));
      assert.ok(!result.stderr.includes(secret));
    }
  );
});

test('models lista los identificadores devueltos por la API', async () => {
  const cfg = newConfigDir();

  await withServer(
    jsonHandler([], { data: [{ id: 'deepseek-chat' }, { id: 'deepseek-reasoner' }] }),
    async (port) => {
      const result = await run(['models'], {
        env: {
          ...baseEnv(cfg),
          DEEPSEEK_API_KEY: 'test-key',
          DEEPSEEK_BASE_URL: `http://127.0.0.1:${port}`,
        },
      });
      assert.equal(result.code, 0);
      assert.match(result.stdout, /deepseek-chat/);
      assert.match(result.stdout, /deepseek-reasoner/);
    }
  );
});

test('la configuración se crea con permisos 0600 y sin claves', async () => {
  const cfg = newConfigDir();

  const init = await run(['config', 'init'], { env: baseEnv(cfg) });
  assert.equal(init.code, 0);

  const file = path.join(cfg, 'deepseek-harness', 'config.json');
  const mode = fs.statSync(file).mode & 0o777;
  assert.equal(mode, 0o600);

  const set = await run(['config', 'set', 'model', 'deepseek-reasoner'], { env: baseEnv(cfg) });
  assert.equal(set.code, 0);

  const show = await run(['config', 'show'], { env: baseEnv(cfg) });
  assert.equal(show.code, 0);
  assert.match(show.stdout, /deepseek-reasoner/);
  assert.ok(!/api.?key/i.test(show.stdout));
});

test('rechaza guardar una clave en la configuración', async () => {
  const cfg = newConfigDir();
  await run(['config', 'init'], { env: baseEnv(cfg) });

  const set = await run(['config', 'set', 'apiKey', 'sk-secreto'], { env: baseEnv(cfg) });
  assert.notEqual(set.code, 0);
  assert.match(set.stderr, /no se guardan|no permitido/i);

  const file = path.join(cfg, 'deepseek-harness', 'config.json');
  assert.ok(!fs.readFileSync(file, 'utf8').includes('sk-secreto'));
});

test('rechaza configuración que ya contiene secretos', async () => {
  const cfg = newConfigDir();
  fs.mkdirSync(path.join(cfg, 'deepseek-harness'), { recursive: true });
  fs.writeFileSync(
    path.join(cfg, 'deepseek-harness', 'config.json'),
    JSON.stringify({ apiKey: 'sk-secreto' })
  );

  const result = await run(['config', 'show'], { env: baseEnv(cfg) });
  assert.equal(result.code, 1);
  assert.match(result.stderr, /sospechoso/);
  assert.ok(!result.stderr.includes('sk-secreto'));
});

test('exige HTTPS fuera de loopback', async () => {
  const cfg = newConfigDir();
  const result = await run(['chat', 'hola'], {
    env: {
      ...baseEnv(cfg),
      DEEPSEEK_API_KEY: 'test-key',
      DEEPSEEK_BASE_URL: 'http://example.com',
    },
  });
  assert.equal(result.code, 1);
  assert.match(result.stderr, /HTTPS/);
});

test('chat --workspace ejecuta herramientas de solo lectura', async () => {
  const cfg = newConfigDir();
  const workspace = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'dh-cli-ws-')));
  fs.writeFileSync(path.join(workspace, 'nota.txt'), 'contenido\n');

  let calls = 0;
  await withServer(
    (req, res) => {
      let raw = '';
      req.on('data', (chunk) => { raw += chunk; });
      req.on('end', () => {
        const body = JSON.parse(raw || '{}');
        calls += 1;
        res.writeHead(200, { 'content-type': 'application/json' });
        if (calls === 1 && Array.isArray(body.tools) && body.tools.length) {
          res.end(JSON.stringify({
            choices: [{
              message: {
                role: 'assistant',
                content: '',
                tool_calls: [{
                  id: 'call_1',
                  type: 'function',
                  function: { name: 'workspace_list', arguments: '{"path":"."}' },
                }],
              },
            }],
          }));
          return;
        }
        res.end(JSON.stringify({ choices: [{ message: { content: 'Veo: nota.txt' } }] }));
      });
    },
    async (port) => {
      const result = await run(['chat', '--workspace', workspace, 'lista'], {
        env: {
          ...baseEnv(cfg),
          DEEPSEEK_API_KEY: 'test-key',
          DEEPSEEK_BASE_URL: `http://127.0.0.1:${port}`,
        },
      });
      assert.equal(result.code, 0);
      assert.equal(result.stdout.trim(), 'Veo: nota.txt');
      assert.match(result.stderr, /\[tool\] workspace_list/);
      assert.match(result.stderr, /\[tool\] ok workspace_list/);
    }
  );
});

test('doctor muestra el workspace configurado', async () => {
  const cfg = newConfigDir();
  const workspace = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'dh-cli-doc-')));
  const result = await run(['doctor', '--workspace', workspace], { env: baseEnv(cfg) });
  assert.match(result.stdout, new RegExp(`workspace:\\s+${workspace.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}`));
  assert.match(result.stdout, /node:.*soportado/);
});
