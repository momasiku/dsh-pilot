// pilot / tools/fixes-smoke.mjs - the four reliability fixes, proven against the real desktop.
//
// 1. abortableWait settles when the turn is aborted (it used to clear the timer and
//    leave the promise pending for the rest of the session).
// 2. An hwnd actually reaches the helper: focus by handle alone, a bogus handle that
//    must fail loudly, and the same handle inside a sequence step (which used to be
//    dropped before it reached the helper).
// 3. A cancelled paste puts the person's clipboard back (the restore now sits in a
//    finally instead of after the keystroke).
// 4. A worker that dies mid-request rejects the pending call instead of throwing
//    TypeError out of the close handler and hanging.
//
// Usage: node tools/fixes-smoke.mjs <app-root>

import { spawn, spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const appRoot = process.argv[2];
if (appRoot === undefined) {
	console.error('usage: node tools/fixes-smoke.mjs <app-root>');
	process.exit(2);
}

const appBase = 'file:///' + appRoot.replaceAll('\\', '/') + '/';
const { validateJsonSchemaValue } = await import(new URL('node_modules/@deepseek-ai/dsh-tools/lib/index.js', appBase).href);
const { Config, apply } = await import(new URL('../lib/index.js', import.meta.url).href);

const sleep = (ms) => new Promise((resolvePromise) => setTimeout(resolvePromise, ms));
let failures = 0;
function check(name, ok, detail) {
	console.log((ok ? 'ok   ' : 'FAIL ') + name + (detail === undefined ? '' : ' - ' + detail));
	if (!ok) failures += 1;
}

const registered = new Map();
const workDir = mkdtempSync(join(tmpdir(), 'pilot-fixes-'));
const ctx = {
	tools: { register(tool) { registered.set(tool.name, tool); } },
	get(service) {
		if (service === 'attachments') {
			return {
				imageLimits: { maxImageBytes: 8 * 1024 * 1024, maxMessageImageBytes: 8 * 1024 * 1024 },
				async saveImage(input) {
					return { attachmentId: 'sha256:stub', mediaType: input.mediaType, bytes: input.data.byteLength, width: 100, height: 100, name: input.name };
				}
			};
		}
		if (service === 'llm') return { async resolveModelInfo() { return { inputModalities: ['text', 'image'] }; } };
		return undefined;
	}
};
apply(ctx, new Config({ stepSettleMs: 60, settleMs: 200 }));

const control = registered.get('desktop_control');
const sequence = registered.get('desktop_sequence');
if (control === undefined || sequence === undefined) throw new Error('the tools did not register');

const exec = {
	signal: undefined,
	agent: {
		options: { provider: 'deepseek', model: 'deepseek-flash' },
		session: {
			header: { cwd: workDir, sessionId: 'fixes-smoke' },
			requestHeader: () => ({ config: { provider: 'deepseek', model: 'deepseek-flash' } })
		}
	}
};

function ps(script) {
	const out = spawnSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', script], { encoding: 'utf8' });
	return (out.stdout ?? '').trim();
}
function clipboardText() {
	return ps('Add-Type -AssemblyName System.Windows.Forms; try { [System.Windows.Forms.Clipboard]::GetText() } catch { "" }');
}
function setClipboard(text) {
	ps('Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.Clipboard]::SetText(' + JSON.stringify(text) + ')');
}

let escaped = null;
process.on('uncaughtException', (error) => { escaped = error; });

// ---- 1. an aborted wait settles -------------------------------------------
{
	const controller = new AbortController();
	const started = Date.now();
	const pending = sequence.execute({ steps: [{ action: 'wait', ms: 30000 }] }, { ...exec, signal: controller.signal });
	setTimeout(() => controller.abort(), 150);
	// The batch catches a per-step rejection and reports it as a failed step, so this
	// check is about the promise settling quickly and naming the cancel - before the
	// fix the wait never settled at all and this raced to HUNG.
	const outcome = await Promise.race([
		pending.then((value) => ({ value }), (error) => ({ error })),
		sleep(4000).then(() => 'HUNG')
	]);
	const elapsed = Date.now() - started;
	const note = outcome === 'HUNG' ? 'HUNG' : String(outcome.value?.steps?.[0]?.note ?? outcome.error?.message ?? 'no note');
	check('an aborted wait settles instead of hanging', outcome !== 'HUNG' && elapsed < 3000, note + ' after ' + elapsed + ' ms');
	check('the failure says it was cancelled', /cancel/i.test(note), note.slice(0, 90));
}

// ---- 2a. focus by hwnd alone ---------------------------------------------
const notepad = spawn('C:\\Windows\\System32\\notepad.exe', [], { detached: true, stdio: 'ignore' });
notepad.unref();
await sleep(2400);
const listed = await control.execute({ action: 'windows', capture: false }, exec);
const target = (listed.windows ?? []).find((entry) => String(entry.process ?? '').toLowerCase() === 'notepad' && entry.visible !== false);
check('notepad is listed with a handle', target !== undefined && typeof target.handle === 'string', target === undefined ? 'not found' : JSON.stringify({ handle: target.handle, title: target.title }));
const handle = target?.handle ?? '0x0';

let focusByHwnd = null;
try {
	focusByHwnd = await control.execute({ action: 'focus', hwnd: handle, capture: false }, exec);
} catch (error) {
	focusByHwnd = { error: error.message };
}
check('focus accepts an hwnd on its own', focusByHwnd?.error === undefined && String(focusByHwnd?.foregroundTitle ?? '').indexOf('记事本') >= 0, focusByHwnd?.error ?? String(focusByHwnd?.foregroundTitle));

// ---- 2b. a stale handle fails loudly ---------------------------------------
let bogus = null;
try {
	await control.execute({ action: 'focus', hwnd: '0x7FFFFFF0', capture: false }, exec);
	bogus = 'accepted a bogus handle';
} catch (error) {
	bogus = error.message;
}
check('a stale hwnd fails with a reason instead of guessing', /no longer exists|no visible top-level window|hwnd/i.test(String(bogus)), String(bogus).slice(0, 90));

// ---- 2c. the same handle inside a batch ------------------------------------
let batch = null;
try {
	batch = await sequence.execute({ steps: [{ action: 'focus', hwnd: handle }, { action: 'type', text: 'HWND-STEP' }], capture: 'none' }, exec);
} catch (error) {
	batch = { error: error.message };
}
check('a sequence step keeps its hwnd', batch?.error === undefined && batch.executed === 2 && String(batch.steps?.[0]?.foregroundTitle ?? '').indexOf('记事本') >= 0, batch?.error ?? JSON.stringify((batch.steps ?? []).map((step) => step.foregroundTitle)));

// ---- 3. a cancelled paste restores the clipboard ---------------------------
{
	const sentinel = 'PILOT-SENTINEL-' + Date.now();
	setClipboard(sentinel);
	const before = clipboardText();
	const controller = new AbortController();
	const pending = control.execute({ action: 'type', text: 'PILOT-PASTED-TEXT', capture: false }, { ...exec, signal: controller.signal }).catch((error) => ({ error: error.message }));
	await sleep(25);
	controller.abort();
	const outcome = await Promise.race([pending, sleep(8000).then(() => ({ error: 'HUNG' }))]);
	const after = clipboardText();
	check('the aborted paste did not hang', outcome?.error !== 'HUNG', String(outcome?.error ?? 'settled').slice(0, 70));
	check('the clipboard came back', before === sentinel && after === sentinel, 'before=' + JSON.stringify(before.slice(0, 40)) + ' after=' + JSON.stringify(after.slice(0, 40)));
}

// ---- 4. killing the worker mid-request -------------------------------------
{
	// The worker has to be the one serving the batch, or the kill proves nothing.
	// A cold first call takes ~3.5 s (spawn + Add-Type); a warm one is tens of ms.
	async function warmWorkerServing() {
		const t = Date.now();
		await control.execute({ action: 'move', x: 420, y: 420, capture: false }, exec).catch(() => undefined);
		return Date.now() - t;
	}
	async function workerPid() {
		return Number(ps("Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { $_.CommandLine -like '*desktop-worker*' } | Select-Object -First 1 -ExpandProperty ProcessId"));
	}

	let outcome = null;
	let killedPid = 0;
	for (let attempt = 1; attempt <= 2 && outcome === null; attempt += 1) {
		const warmMs = await warmWorkerServing();
		const pid = await workerPid();
		if (!Number.isInteger(pid) || pid <= 0) { check('the warm worker is running', false, 'no pid'); break; }
		if (warmMs > 800) {
			check('the warm worker is serving', false, 'a warm move took ' + warmMs + ' ms, so the batch would not use it');
			break;
		}
		killedPid = pid;
		const pending = sequence.execute({ steps: [
			{ action: 'drag', x: 300, y: 300, toX: 900, toY: 700 },
			{ action: 'drag', x: 900, y: 700, toX: 300, toY: 300 }
		], capture: 'none' }, exec).then((value) => ({ ok: true, value }), (error) => ({ ok: false, error: error.message }));
		await sleep(200);
		try { process.kill(pid); } catch (error) { check('the worker could be killed', false, error.message); break; }
		const settled = await Promise.race([pending, sleep(8000).then(() => ({ ok: false, error: 'HUNG' }))]);
		if (settled.error === 'HUNG') { outcome = settled; break; }
		// A resolved batch is acceptable only if it reports the step it lost. If the
		// batch still succeeded, the pid we killed was stale - try once more.
		const reported = settled.ok === true ? (settled.value?.failed ?? 0) > 0 : true;
		if (reported || attempt === 2) outcome = settled;
	}
	if (outcome !== null) {
		check('the warm worker is running', killedPid > 0, 'pid=' + killedPid);
		const detail = outcome.ok === true ? 'resolved failed=' + (outcome.value?.failed ?? '?') : String(outcome.error).slice(0, 60);
		check('a dead worker rejects the pending call instead of hanging', outcome.error !== 'HUNG' && (outcome.ok === false || (outcome.value?.failed ?? 0) > 0), 'killed=[' + killedPid + '] ' + detail);
		check('no exception escaped the worker close handler', escaped === null, escaped === null ? 'none' : escaped.message);
	}
}

try { process.kill(notepad.pid); } catch { /* already gone */ }
rmSync(workDir, { recursive: true, force: true });

console.log('');
if (failures > 0) { console.log('fixes-smoke: ' + failures + ' check(s) failed'); process.exit(1); }
console.log('fixes-smoke: OK');
