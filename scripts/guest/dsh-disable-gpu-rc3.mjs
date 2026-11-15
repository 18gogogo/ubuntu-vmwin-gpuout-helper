import fs from 'fs';
const asarPath = 'C:/Users/win11vmvm/AppData/Local/Programs/DeepSeek Harness/resources/app.asar';
const CODE = 'app.commandLine.appendSwitch("disable-gpu");';
const ANCHOR = '/** IPC channel names kept private to the desktop application bundle. */';
const b = fs.readFileSync(asarPath);
if (b.indexOf(Buffer.from(CODE)) !== -1) { console.log('already patched (CODE present); nothing to do'); process.exit(0); }
const hSize = b.readUInt32LE(12);
const dataStart = 16 + Math.ceil(hSize / 4) * 4;
const header = JSON.parse(b.slice(16, 16 + hSize).toString('utf8'));
let main = null;
(function walk(node, prefix) {
  for (const [name, val] of Object.entries(node.files || {})) {
    const p = prefix ? prefix + '/' + name : name;
    if (val.files) walk(val, p);
    else if (p === 'lib/main.js') main = { off: parseInt(val.offset, 10), size: val.size };
  }
})(header, '');
if (!main) { console.error('lib/main.js not found in asar header'); process.exit(1); }
const regionStart = dataStart + main.off;
const region = b.subarray(regionStart, regionStart + main.size);
const anchorB = Buffer.from(ANCHOR, 'utf8');
const ai = region.indexOf(anchorB);
if (ai === -1) { console.error('anchor not found in main.js region'); process.exit(1); }
if (region.indexOf(anchorB, ai + 1) !== -1) { console.error('anchor not unique in main.js'); process.exit(1); }
if (ANCHOR.length < CODE.length) { console.error('anchor shorter than code'); process.exit(1); }
const newB = Buffer.from(CODE + ' '.repeat(ANCHOR.length - CODE.length), 'utf8');
if (newB.length !== ANCHOR.length) { console.error('length mismatch'); process.exit(1); }
const bak = asarPath + '.bak-disable-gpu-2026-11-14';
if (!fs.existsSync(bak)) { fs.copyFileSync(asarPath, bak); console.log('backup created:', bak); } else console.log('backup already exists (kept):', bak);
const fd = fs.openSync(asarPath, 'r+');
try { fs.writeSync(fd, newB, 0, newB.length, regionStart + ai); } finally { fs.closeSync(fd); }
const after = fs.readFileSync(asarPath);
const v = after.indexOf(newB);
console.log('asar size unchanged:', after.length === b.length);
console.log('patched at asar offset', regionStart + ai, '(', 'main.js offset', ai, ')');
console.log('verify:', v === regionStart + ai ? 'OK' : 'MISMATCH at ' + v);
process.exit(v === regionStart + ai ? 0 : 2);
