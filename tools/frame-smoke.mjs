// pilot / tools/frame-smoke.mjs - the end frame survives the window it describes.
//
// What is proven here, against a real desktop:
//   1. a frame can be addressed by handle, and a stale handle is refused by name;
//   2. a batch's end frame is taken by handle, and when the window is gone the frame
//      falls back to the screen and says so instead of vanishing;
//   3. `windows` hides input-method furniture by default and returns it on request;
//   4. a frame is opt-in on desktop_control.
//
// Usage: node tools/frame-smoke.mjs <app-root>

import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

process.env.DSH_PILOT_SCRATCH_DIR = mkdtempSync(join(tmpdir(), 'pilot-scratch-'));

const appRoot = process.argv[2];
if (appRoot === undefined) { console.error('usage: node tools/frame-smoke.mjs <app-root>'); process.exit(2); }
const appBase = 'file:///' + appRoot.replaceAll('\\', '/') + '/';
await import(new URL('node_modules/@deepseek-ai/dsh-tools/lib/index.js', appBase).href);
const { Config, apply } = await import(new URL('../lib/index.js', import.meta.url).href);

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let failures = 0;
function check(name, ok, detail) {
  console.log((ok ? 'ok   ' : 'FAIL ') + name + (detail === undefined ? '' : ' - ' + detail));
  if (!ok) failures += 1;
}

const registered = new Map();
const workDir = mkdtempSync(join(tmpdir(), 'pilot-frame-'));
const ctx = {
  tools: { register(t) { registered.set(t.name, t); } },
  get(s) {
    if (s === 'attachments') return {
      imageLimits: { maxImageBytes: 8e6, maxMessageImageBytes: 8e6 },
      async saveImage(i) { return { attachmentId: 'sha256:stub', mediaType: i.mediaType, bytes: i.data.byteLength, width: 1, height: 1, name: i.name }; }
    };
    if (s === 'llm') return { async resolveModelInfo() { return { inputModalities: ['text', 'image'] }; } };
    return undefined;
  }
};
apply(ctx, new Config({ stepSettleMs: 60, settleMs: 200 }));
const control = registered.get('desktop_control');
const sequence = registered.get('desktop_sequence');
const view = registered.get('screen_view');
const exec = { signal: undefined, agent: { options: { provider: 'deepseek', model: 'deepseek-flash' }, session: { header: { cwd: workDir, sessionId: 'frame-smoke-' + Date.now() }, requestHeader: () => ({ config: { provider: 'deepseek', model: 'deepseek-flash' } }) } } };

const BOM = String.fromCharCode(0xFEFF);
const stamp = Math.random().toString(36).slice(2, 8);
const title = 'dsh-pilot frame ' + stamp;
const readyFile = join(workDir, 'ready-' + stamp + '.txt');
const windowPath = join(workDir, 'window-' + stamp + '.ps1');
const launcherPath = join(workDir, 'launch-' + stamp + '.ps1');

const windowScript = [
  'Add-Type -AssemblyName System.Windows.Forms',
  '$form = New-Object System.Windows.Forms.Form',
  "$form.Text = '" + title + "'",
  '$form.Width = 460',
  '$form.Height = 220',
  "$form.StartPosition = 'CenterScreen'",
  '$box = New-Object System.Windows.Forms.TextBox',
  "$box.Dock = 'Fill'",
  '$form.Controls.Add($box)',
  "$form.Add_Shown({ [System.IO.File]::WriteAllText('" + readyFile + "', [string]$PID); $box.Focus() })",
  '[System.Windows.Forms.Application]::Run($form)'
].join('\r\n');
writeFileSync(windowPath, BOM + windowScript, 'utf8');
writeFileSync(launcherPath, BOM + "Start-Process -FilePath powershell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File','" + windowPath + "')", 'utf8');

rmSync(readyFile, { force: true });
spawnSync('powershell', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', launcherPath], { stdio: 'ignore' });
for (let i = 0; i < 40 && !existsSync(readyFile); i += 1) await sleep(250);
if (!existsSync(readyFile)) {
  console.log('FAIL the throwaway window did not start');
  rmSync(workDir, { recursive: true, force: true });
  process.exit(1);
}
check('the throwaway window came up', true, title);

const listed = await control.execute({ action: 'windows', title: title, capture: false }, exec);
const win = (listed.windows ?? [])[0];
check('the window is listed with a handle', win !== undefined && typeof win.handle === 'string', win === undefined ? 'missing' : win.handle);
if (win === undefined) {
  console.log('frame-smoke: cannot continue without the fixture window');
  rmSync(workDir, { recursive: true, force: true });
  process.exit(1);
}

const byHandle = await view.execute({ hwnd: win.handle }, exec);
check('screen_view frames a window by handle', byHandle.kind === 'window' && byHandle.imageWidth < 900 && byHandle.imageHeight < 600, byHandle.kind + ' ' + byHandle.imageWidth + 'x' + byHandle.imageHeight);

const front = await view.execute({ foreground: true }, exec);
check('screen_view frames the foreground window on request', front.kind === 'window' && front.imageWidth > 100, front.kind + ' ' + front.imageWidth + 'x' + front.imageHeight);

let stale = '';
try { await view.execute({ hwnd: '0x7FFFFFF0' }, exec); stale = 'accepted'; } catch (error) { stale = error.message; }
check('a stale handle is refused by name', /no longer exists/.test(stale), String(stale).slice(0, 70));

const batch = await sequence.execute({ steps: [ { action: 'focus', hwnd: win.handle }, { action: 'type', text: 'frame ok' } ], capture: 'end', target: 'window' }, exec);
check('every step reports the foreground handle', typeof batch.steps?.[0]?.foregroundHwnd === 'string', JSON.stringify(batch.steps?.[0]?.foregroundHwnd));
check('the batch result carries the handle', typeof batch.foregroundHwnd === 'string', JSON.stringify(batch.foregroundHwnd));
check('the end frame still arrives', batch.capture?.image !== undefined, batch.capture === undefined ? 'none' : batch.capture.kind);
check('the end frame is the window, not the desktop', batch.capture?.kind === 'window' && batch.capture.imageWidth < 900, batch.capture === undefined ? 'no frame' : batch.capture.kind + ' ' + batch.capture.imageWidth + 'x' + batch.capture.imageHeight);
check('no fallback was needed', batch.captureFallback === undefined, String(batch.captureFallback ?? ''));

// The window has to be gone between the last step and the frame: kill the fixture
// process while the batch is sitting in a wait, which is exactly the shape of a batch
// whose target disappears on it.
const windowPid = Number(readFileSync(readyFile, 'utf8').trim());
const pending = sequence.execute({ steps: [ { action: 'focus', hwnd: win.handle }, { action: 'wait', ms: 1500 } ], capture: 'end', target: 'window' }, exec);
await sleep(400);
spawnSync('powershell', ['-NoProfile', '-Command', 'Stop-Process -Id ' + windowPid + ' -Force'], { stdio: 'ignore' });
const closed = await pending;
check('the batch still finished', closed.executed === 2 && closed.failed === 0, 'executed=' + closed.executed + ' failed=' + closed.failed);
check('a frame is still returned after the window is gone', closed.capture?.image !== undefined, closed.capture === undefined ? 'none' : closed.capture.kind);
check('the fallback is reported, not silent', typeof closed.captureFallback === 'string' && /could not be framed/.test(closed.captureFallback), String(closed.captureFallback ?? '').slice(0, 90));
check('the fallback frames a window rather than the whole screen', /foreground window|last title/.test(String(closed.captureFallback ?? '')) ? closed.capture?.kind === 'window' : true, closed.capture?.kind + ' / ' + String(closed.captureFallback ?? '').slice(0, 70));

const plain = await control.execute({ action: 'windows', capture: false }, exec);
const rows = plain.windows ?? [];
const furniture = rows.filter((w) => /Default IME|MSCTFIME UI|MSCTFUI|GDI\+ Window/.test(String(w.title ?? '')) || /,[0-9-]+,0,0$/.test(String(w.bounds ?? '')));
check('no input-method furniture by default', furniture.length === 0, furniture.length + ' leaked: ' + JSON.stringify(furniture.slice(0, 2)));
check('the drop is counted', (plain.filteredOut ?? 0) > 0, 'filteredOut=' + plain.filteredOut + ' windowTotal=' + plain.windowTotal);
check('windowTotal covers the filtered rows', (plain.windowTotal ?? 0) === rows.length + (plain.filteredOut ?? 0), 'total=' + plain.windowTotal + ' listed=' + rows.length + ' filtered=' + plain.filteredOut);
const everything = await control.execute({ action: 'windows', includeSystem: true, capture: false }, exec);
check('includeSystem returns the furniture', (everything.filteredOut ?? 0) === 0 && (everything.windows ?? []).length > rows.length, 'listed=' + (everything.windows ?? []).length + ' vs ' + rows.length);

// No `capture` at all: this is the default, not an explicit opt-out.
const quiet = await control.execute({ action: 'windows' }, exec);
check('no frame unless asked', quiet.capture === undefined && quiet.capturePath === undefined, 'capture=' + JSON.stringify(quiet.capture));
const loud = await control.execute({ action: 'windows', capture: true }, exec);
check('capture:true still takes one', loud.capture?.image !== undefined, loud.capturePath === undefined ? 'none' : 'ok');

rmSync(workDir, { recursive: true, force: true });
console.log('');
if (failures > 0) { console.log('frame-smoke: ' + failures + ' check(s) failed'); process.exit(1); }
console.log('frame-smoke: OK');
// Exit explicitly: the plugin keeps a warm PowerShell worker for the life of the host,
// and its pipes keep this process alive long after the last check has printed.
process.exit(0);
