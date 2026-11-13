#!/usr/bin/env node
// dsh-disable-gpu.mjs — patch DSH desktop's app.asar to force software rendering
// (Chromium --disable-gpu), fixing renderer crashes on machines with an unstable
// passed-through GPU.
//
// Technique: SAME-LENGTH IN-PLACE edit (the asar file size and per-file offsets are
// unchanged), so Electron's asar-integrity check (if the build uses one) keeps passing.
// The patch replaces one standalone single-line JSDoc comment with:
//     app.commandLine.appendSwitch("disable-gpu");
// (padded with spaces to the same byte length).
//
// A backup is created first:  app.asar.bak-disable-gpu-<YYYY-MM-DD>
//
// Usage:
//   node dsh-disable-gpu.mjs [path-to-app.asar]
//   (default: auto-detect under %LOCALAPPDATA%/Programs/DeepSeek Harness/resources/app.asar)
//
// After patching: fully quit and relaunch DSH.
// To revert: replace app.asar with the .bak file (quit DSH first).
import fs from 'node:fs';
import path from 'node:path';

const CODE = 'app.commandLine.appendSwitch("disable-gpu");';
// Proven anchor (dsh-desktop 0.2.2-rc.1): the JSDoc comment above quitWithoutConfirmation().
const PROVEN_OLD = '/** Quit without the task confirmation; the caller has already decided the application must stop. */';

function defaultAsar() {
  if (process.platform === 'win32') {
    return path.join(process.env.LOCALAPPDATA || '', 'Programs', 'DeepSeek Harness', 'resources', 'app.asar');
  }
  return path.join(process.env.HOME || '', 'snap', 'deepseek-harness', 'current', 'resources', 'app.asar');
}

const asarPath = process.argv[2] || defaultAsar();
if (!fs.existsSync(asarPath)) {
  console.error('app.asar not found:', asarPath, '\nPass the path explicitly: node dsh-disable-gpu.mjs <path-to-app.asar>');
  process.exit(2);
}

const buf = fs.readFileSync(asarPath);
let oldStr = PROVEN_OLD;
let oldIdx = buf.indexOf(Buffer.from(PROVEN_OLD, 'utf8'));

if (oldIdx === -1) {
  // Generic fallback (other app versions): first standalone single-line /** ... */ comment
  // (scanned over the first 64 MiB of the archive) that is at least as long as CODE.
  const head = buf.subarray(0, 64 * 1024 * 1024).toString('latin1');
  const re = /^\/\*\* [^\n]*? \*\/$/gm;
  let m;
  while ((m = re.exec(head)) !== null) {
    if (m[0].length >= CODE.length) { oldStr = m[0]; oldIdx = m.index; break; }
  }
  if (oldIdx === -1) {
    console.error('no suitable same-length anchor comment found; aborting (no changes made)');
    process.exit(3);
  }
  console.log('proven anchor not found; using generic anchor (first suitable JSDoc comment line):');
  console.log('  ', oldStr.length > 90 ? oldStr.slice(0, 87) + '...' : oldStr);
}
if (oldStr.length < CODE.length) { console.error('anchor shorter than code; aborting (no changes made)'); process.exit(4); }
const newStr = CODE + ' '.repeat(oldStr.length - CODE.length);
const oldB = Buffer.from(oldStr, 'utf8');
const newB = Buffer.from(newStr, 'utf8');

// --- backup ---
const stamp = new Date().toISOString().slice(0, 10);
const bak = `${asarPath}.bak-disable-gpu-${stamp}`;
if (!fs.existsSync(bak)) {
  fs.copyFileSync(asarPath, bak);
  console.log('backup created:', bak);
} else {
  console.log('backup already exists (kept):', bak);
}

// --- in-place patch (same length) ---
const fd = fs.openSync(asarPath, 'r+');
let patched = 0;
try {
  let idx = buf.indexOf(oldB);
  while (idx !== -1) {
    fs.writeSync(fd, newB, 0, newB.length, idx);
    patched++;
    idx = buf.indexOf(oldB, idx + oldB.length);
  }
} finally {
  fs.closeSync(fd);
}
console.log(`patched ${patched} occurrence(s); ${oldB.length} bytes each (same length — asar hash/offsets preserved)`);
if (patched === 0) process.exit(5);

// --- verify ---
const after = fs.readFileSync(asarPath);
const v = after.indexOf(newB);
console.log('verify: patched string present at offset', v);
if (v === -1) process.exit(6);
console.log('done. Fully quit and relaunch DSH for the switch to take effect.');
console.log('Revert: quit DSH, then replace app.asar with', bak);
