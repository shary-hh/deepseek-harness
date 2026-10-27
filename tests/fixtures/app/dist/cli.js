#!/usr/bin/env node
'use strict';

const path = require('path');
const pkg = require(path.join(__dirname, '..', 'package.json'));
const args = process.argv.slice(2);

if (args.includes('--version') || args.includes('-v')) {
  console.log(pkg.version);
  process.exit(0);
}

if (args.includes('--help') || args.includes('-h')) {
  console.log(`deepseek-harness ${pkg.version}`);
  console.log('Uso: deepseek-harness [--version] [--help]');
  process.exit(0);
}

console.log(`deepseek-harness ${pkg.version} listo`);
