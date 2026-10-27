#!/usr/bin/env node
'use strict';

/*
 * Esqueleto de la CLI deepseek-harness.
 *
 * Reemplaza este archivo por tu aplicación real. Lo único importante para el
 * empaquetado es que `package.json` apunte `bin."deepseek-harness"` a un
 * entrypoint Node.js válido.
 *
 * Regla de oro: este proceso NUNCA imprime ni escribe claves de API.
 */

const fs = require('fs');
const os = require('os');
const path = require('path');

const pkg = require(path.join(__dirname, '..', 'package.json'));

function configDir() {
  const base = process.env.XDG_CONFIG_HOME || path.join(os.homedir(), '.config');
  return path.join(base, 'deepseek-harness');
}

function printHelp() {
  const name = pkg.name;
  console.log(`${name} ${pkg.version}

Uso:
  ${name} <comando> [opciones]

Comandos:
  doctor        Comprueba el entorno sin mostrar secretos
  config        Muestra rutas de configuración
  chat          (stub) punto de entrada de tu implementación

Opciones:
  -h, --help      Muestra esta ayuda
  -v, --version   Muestra la versión

Entorno:
  DEEPSEEK_API_KEY   Clave de API (nunca se imprime ni se guarda)

Este es el esqueleto de ejemplo: sustituye app/dist/cli.js por tu aplicación.
`);
}

function doctor() {
  const key = process.env.DEEPSEEK_API_KEY;
  console.log('Entorno de deepseek-harness');
  console.log(`  versión:        ${pkg.version}`);
  console.log(`  node:           ${process.version}`);
  console.log(`  plataforma:     ${process.platform}/${process.arch}`);
  console.log(`  DEEPSEEK_API_KEY: ${key ? 'definida (valor oculto)' : 'no definida'}`);
  console.log(`  config:         ${configDir()}`);
  process.exit(key ? 0 : 1);
}

function showConfig() {
  console.log(`directorio de configuración: ${configDir()}`);
  console.log('No se escribe nada automáticamente: crea la configuración con modo 0700.');
}

function chat() {
  console.error('El comando "chat" es un stub. Implementa tu lógica en app/dist/cli.js.');
  process.exit(2);
}

function main(argv) {
  const [cmd] = argv;

  if (!cmd || cmd === '-h' || cmd === '--help' || cmd === 'help') {
    printHelp();
    return;
  }
  if (cmd === '-v' || cmd === '--version' || cmd === 'version') {
    console.log(pkg.version);
    return;
  }

  switch (cmd) {
    case 'doctor':
      doctor();
      break;
    case 'config':
      showConfig();
      break;
    case 'chat':
      chat();
      break;
    default:
      console.error(`Comando desconocido: ${cmd}`);
      printHelp();
      process.exit(64);
  }
}

// Si el runtime no expone una versión moderna, falla con un mensaje claro.
const major = Number(process.versions.node.split('.')[0]);
if (major < 20) {
  console.error(`deepseek-harness requiere Node.js >= 20 (detectado ${process.version}).`);
  process.exit(1);
}

main(process.argv.slice(2));
