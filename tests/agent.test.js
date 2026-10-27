#!/usr/bin/env node
'use strict';

/*
 * Pruebas del bucle de tool calling contra un backend mock.
 */

const { test } = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const { runAgent } = require('../app/dist/agent');

function makeWorkspace() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dh-agent-'));
  fs.writeFileSync(path.join(root, 'nota.txt'), 'contenido de prueba\n');
  return fs.realpathSync(root);
}

function startApi(handler) {
  const server = http.createServer(handler);
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => resolve({ server, port: server.address().port }));
  });
}

function cfgFor(port) {
  return {
    baseUrl: `http://127.0.0.1:${port}`,
    model: 'deepseek-chat',
    temperature: 1,
    maxTokens: 256,
    timeoutMs: 5000,
  };
}

test('ejecuta una herramienta y devuelve la respuesta final', async () => {
  const workspace = makeWorkspace();
  const requests = [];

  const { server, port } = await startApi((req, res) => {
    let raw = '';
    req.on('data', (chunk) => { raw += chunk; });
    req.on('end', () => {
      const body = JSON.parse(raw);
      requests.push(body);
      res.writeHead(200, { 'content-type': 'application/json' });

      if (requests.length === 1) {
        res.end(JSON.stringify({
          choices: [{
            message: {
              role: 'assistant',
              content: '',
              tool_calls: [{
                id: 'call_1',
                type: 'function',
                function: { name: 'workspace_list', arguments: '{"path":".","depth":1}' },
              }],
            },
          }],
        }));
        return;
      }

      res.end(JSON.stringify({
        choices: [{ message: { role: 'assistant', content: 'Veo nota.txt' } }],
        usage: { total_tokens: 42 },
      }));
    });
  });

  const events = [];
  try {
    const result = await runAgent({
      cfg: cfgFor(port),
      key: 'test-key',
      model: 'deepseek-chat',
      messages: [{ role: 'user', content: 'lista los archivos' }],
      workspace,
      onEvent: (event) => events.push(event),
    });

    assert.equal(result.content, 'Veo nota.txt');
    assert.equal(result.steps, 2);
    assert.equal(events[0].type, 'tool');
    assert.equal(events[0].name, 'workspace_list');
    assert.equal(events[1].type, 'tool_result');
    assert.equal(events[1].ok, true);
    assert.match(events[1].summary, /entradas/);

    const toolMessage = requests[1].messages.find((message) => message.role === 'tool');
    assert.ok(toolMessage);
    assert.equal(toolMessage.tool_call_id, 'call_1');
    assert.match(toolMessage.content, /nota\.txt/);
    assert.equal(requests[0].tools.length, 2);
  } finally {
    server.close();
  }
});

test('devuelve el error de la herramienta al modelo sin romper el bucle', async () => {
  const workspace = makeWorkspace();
  const requests = [];

  const { server, port } = await startApi((req, res) => {
    let raw = '';
    req.on('data', (chunk) => { raw += chunk; });
    req.on('end', () => {
      requests.push(JSON.parse(raw));
      res.writeHead(200, { 'content-type': 'application/json' });
      if (requests.length === 1) {
        res.end(JSON.stringify({
          choices: [{
            message: {
              role: 'assistant',
              content: '',
              tool_calls: [{
                id: 'call_2',
                type: 'function',
                function: { name: 'workspace_read', arguments: '{"path":"../fuera.txt"}' },
              }],
            },
          }],
        }));
        return;
      }
      res.end(JSON.stringify({ choices: [{ message: { content: 'No pude leerlo' } }] }));
    });
  });

  const events = [];
  try {
    const result = await runAgent({
      cfg: cfgFor(port),
      key: 'test-key',
      model: 'deepseek-chat',
      messages: [{ role: 'user', content: 'lee fuera' }],
      workspace,
      onEvent: (event) => events.push(event),
    });

    assert.equal(result.content, 'No pude leerlo');
    const failure = events.find((event) => event.type === 'tool_result');
    assert.equal(failure.ok, false);
    assert.match(failure.summary, /\.\.|fuera|relativa/i);

    const toolMessage = requests[1].messages.find((message) => message.role === 'tool');
    assert.match(toolMessage.content, /error/);
  } finally {
    server.close();
  }
});

test('corta el bucle tras el máximo de pasos', async () => {
  const workspace = makeWorkspace();
  let calls = 0;

  const { server, port } = await startApi((req, res) => {
    req.resume();
    req.on('end', () => {
      calls += 1;
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({
        choices: [{
          message: {
            role: 'assistant',
            content: '',
            tool_calls: [{
              id: `call_${calls}`,
              type: 'function',
              function: { name: 'workspace_list', arguments: '{"path":"."}' },
            }],
          },
        }],
      }));
    });
  });

  try {
    await assert.rejects(
      runAgent({
        cfg: cfgFor(port),
        key: 'test-key',
        model: 'deepseek-chat',
        messages: [{ role: 'user', content: 'loop' }],
        workspace,
        maxSteps: 3,
      }),
      /superó 3 pasos/i
    );
    assert.equal(calls, 3);
  } finally {
    server.close();
  }
});
