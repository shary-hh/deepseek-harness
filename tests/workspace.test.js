#!/usr/bin/env node
'use strict';

/*
 * Pruebas del workspace de solo lectura: sandbox, secretos y límites.
 */

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const {
  resolveWorkspace,
  listFiles,
  readFile,
  executeTool,
} = require('../app/dist/workspace');

function makeWorkspace() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dh-ws-'));
  fs.mkdirSync(path.join(root, 'sub'), { recursive: true });
  fs.mkdirSync(path.join(root, '.git'), { recursive: true });
  fs.mkdirSync(path.join(root, 'node_modules'), { recursive: true });
  fs.writeFileSync(path.join(root, 'a.txt'), 'hola mundo\n');
  fs.writeFileSync(path.join(root, 'sub', 'b.txt'), 'contenido b\n');
  fs.writeFileSync(path.join(root, '.env'), 'SECRETO=1\n');
  fs.writeFileSync(path.join(root, 'server.pem'), 'FAKE\n');
  fs.writeFileSync(path.join(root, '.git', 'config'), 'url = https://token@x\n');
  fs.writeFileSync(path.join(root, 'node_modules', 'x.js'), 'x\n');

  const outside = fs.mkdtempSync(path.join(os.tmpdir(), 'dh-out-'));
  fs.writeFileSync(path.join(outside, 'secreto.txt'), 'no deberías leer esto\n');
  fs.symlinkSync(path.join(outside, 'secreto.txt'), path.join(root, 'link.txt'));

  return { root: fs.realpathSync(root), outside };
}

test('lista archivos y omite secretos y directorios peligrosos', () => {
  const { root } = makeWorkspace();
  const result = listFiles(root, { path: '.', depth: 2 });
  const paths = result.entries.map((entry) => entry.path);

  assert.ok(paths.includes('a.txt'));
  assert.ok(paths.includes('sub'));
  assert.ok(paths.includes('sub/b.txt'));
  assert.ok(!paths.some((p) => p.includes('.env')));
  assert.ok(!paths.some((p) => p.includes('server.pem')));
  assert.ok(!paths.some((p) => p.includes('.git')));
  assert.ok(!paths.some((p) => p.includes('node_modules')));
});

test('lee archivos de texto dentro del workspace', () => {
  const { root } = makeWorkspace();
  const result = readFile(root, { path: 'sub/b.txt' });
  assert.equal(result.content, 'contenido b\n');
  assert.equal(result.path, 'sub/b.txt');
});

test('rechaza lectura de archivos sensibles', () => {
  const { root } = makeWorkspace();
  assert.throws(() => readFile(root, { path: '.env' }), /bloqueado|seguridad/i);
  assert.throws(() => readFile(root, { path: 'server.pem' }), /bloqueado|seguridad/i);
});

test('rechaza traversal, rutas absolutas y symlinks que escapan', () => {
  const { root } = makeWorkspace();
  assert.throws(() => readFile(root, { path: '../secreto.txt' }), /\.\.|fuera/i);
  assert.throws(() => readFile(root, { path: '/etc/passwd' }), /relativa/i);
  assert.throws(() => readFile(root, { path: 'link.txt' }), /symlink|fuera/i);
});

test('rechaza binarios y archivos demasiado grandes', () => {
  const { root } = makeWorkspace();
  fs.writeFileSync(path.join(root, 'binario.dat'), Buffer.from([1, 2, 0, 4]));
  assert.throws(() => readFile(root, { path: 'binario.dat' }), /binario/i);

  fs.writeFileSync(path.join(root, 'grande.txt'), 'x'.repeat(129 * 1024));
  assert.throws(() => readFile(root, { path: 'grande.txt' }), /demasiado grande/i);
});

test('limita la profundidad y el número de entradas', () => {
  const { root } = makeWorkspace();
  const shallow = listFiles(root, { path: '.', depth: 1 });
  assert.ok(!shallow.entries.some((entry) => entry.path === 'sub/b.txt'));

  const clamped = listFiles(root, { path: '.', depth: 99 });
  assert.equal(clamped.limits.maxDepth, 3);
});

test('executeTool rechaza herramientas desconocidas', () => {
  const { root } = makeWorkspace();
  assert.throws(() => executeTool(root, 'rm_rf', {}), /desconocida/i);
});

test('resolveWorkspace valida el directorio', () => {
  assert.equal(resolveWorkspace(null), null);
  assert.throws(() => resolveWorkspace('/ruta/que/no/existe'), /No existe/i);
  const { root } = makeWorkspace();
  assert.equal(resolveWorkspace(root), root);
});
