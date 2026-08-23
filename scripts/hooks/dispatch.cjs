#!/usr/bin/env node
// Cross-platform hook launcher: PowerShell on Windows, Bash elsewhere.

'use strict';

const { spawnSync } = require('node:child_process');
const path = require('node:path');

const hook = process.argv[2];
if (!['on_session_start', 'post_edit', 'on_stop'].includes(hook)) {
  process.stderr.write(`unknown feedback-harness hook: ${hook || '(missing)'}\n`);
  process.exit(2);
}

const input = require('node:fs').readFileSync(0);
const directory = __dirname;
const windows = process.platform === 'win32';
const command = windows ? 'powershell.exe' : 'bash';
const args = windows
  ? ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(directory, `${hook}.ps1`)]
  : [path.join(directory, `${hook}.sh`)];

const result = spawnSync(command, args, {
  input,
  stdio: ['pipe', 'pipe', 'pipe'],
  windowsHide: true,
});

if (result.stdout) process.stdout.write(result.stdout);
if (result.stderr) process.stderr.write(result.stderr);
if (result.error) {
  process.stderr.write(`${result.error.message}\n`);
  process.exit(2);
}
process.exit(result.status ?? 2);
