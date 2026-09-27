// End-to-end smoke for `desktop_sequence`.
//
// It drives the REAL tool against the REAL desktop, but only ever touches a
// throwaway WinForms window it creates itself (unique CJK title): the batch
// focuses that window, types text, presses Enter, and the window writes what it
// received to a temp file. That write-back proves the batch really ran in order
// — focus first, then the text — which a screenshot alone cannot show.
//
// It also checks the gates that must hold without touching anything (a
// medium/high-risk batch is refused without confirm, dryRun plans without
// executing, a malformed step is rejected), the frame deduplication, and the
// closed output schema of the result.
//
// Usage: node tools/sequence-smoke.mjs "D:\\AGAENT\\DSH Desktop\\resources\\app"
import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const appRoot = process.argv[2];
if (appRoot === undefined) {
	console.error('usage: node tools/sequence-smoke.mjs <app-root>');
	process.exit(2);
}

const appBase = `file:///${appRoot.replaceAll('\\', '/')}/`;
const { validateJsonSchemaValue } = await import(new URL('node_modules/@deepseek-ai/dsh-tools/lib/index.js', appBase).href);
const { Config, apply } = await import(new URL('../lib/index.js', import.meta.url).href);

const sleep = (ms) => new Promise((resolvePromise) => setTimeout(resolvePromise, ms));
let failures = 0;
function check(name, ok, detail) {
	console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${detail === undefined ? '' : ` — ${detail}`}`);
	if (!ok) failures += 1;
}

// ── stub context ────────────────────────────────────────────────────────────
const registered = new Map();
const workDir = mkdtempSync(join(tmpdir(), 'pilot-seq-'));
const attachments = [];
const ctx = {
	tools: { register(tool) { registered.set(tool.name, tool); } },
	get(service) {
		if (service === 'attachments') {
			return {
				imageLimits: { maxImageBytes: 8 * 1024 * 1024, maxMessageImageBytes: 8 * 1024 * 1024 },
				async saveImage(input) {
					attachments.push({ bytes: input.data.byteLength, name: input.name });
					return { attachmentId: `sha256:stub-${attachments.length}`, mediaType: input.mediaType, bytes: input.data.byteLength, width: 690, height: 450, name: input.name };
				}
			};
		}
		if (service === 'llm') return { async resolveModelInfo() { return { inputModalities: ['text', 'image'] }; } };
		return undefined;
	}
};
apply(ctx, new Config({ stepSettleMs: 120, settleMs: 500 }));

const sequence = registered.get('desktop_sequence');
if (sequence === undefined) throw new Error('desktop_sequence was not registered');

const exec = {
	signal: undefined,
	agent: {
		options: { provider: 'deepseek', model: 'deepseek-flash' },
		session: {
			header: { cwd: workDir, sessionId: 'sequence-smoke' },
			requestHeader: () => ({ config: { provider: 'deepseek', model: 'deepseek-flash' } })
		}
	}
};

// ── gates that must hold before anything runs ───────────────────────────────
let refused = null;
try {
	await sequence.execute({ steps: [{ action: 'click', x: 10, y: 10, risk: 'high', riskNote: 'closes the app' }] }, exec);
} catch (error) {
	refused = error;
}
check('high-risk step without confirm is refused', refused !== null && /declared high risk/.test(refused.message));
check('the refusal names the offending step', refused !== null && /#1 click \(closes the app\)/.test(refused.message));

const planned = await sequence.execute({
	steps: [{ action: 'move', x: 1, y: 1 }, { action: 'wait', ms: 5 }],
	dryRun: true,
	risk: 'medium',
	confirm: true
}, exec);
check('dryRun plans without executing', planned.planned === true && planned.executed === 0 && planned.stepCount === 2, planned.steps.map((s) => s.action).join(','));

let badStep = null;
try {
	await sequence.execute({ steps: [{ action: 'click', x: 1 }] }, exec);
} catch (error) {
	badStep = error;
}
check('a malformed step is rejected before running', badStep !== null && /needs integer x and y/.test(badStep.message));

// ── the throwaway window ────────────────────────────────────────────────────
const stamp = Math.random().toString(36).slice(2, 8);
const title = `dsh-pilot 冒烟 ${stamp}`;
const receivedFile = join(workDir, `received-${stamp}.txt`);
const readyFile = join(workDir, `ready-${stamp}.txt`);
const windowScriptPath = join(workDir, `throwaway-${stamp}.ps1`);
const launcherPath = join(workDir, `launch-${stamp}.ps1`);
const typed = 'pilot 中文 123';

// The window reports its own PID and title as soon as it is shown, so the smoke
// waits for evidence instead of sleeping and hoping.
const windowScript = `
Add-Type -AssemblyName System.Windows.Forms
$form = New-Object System.Windows.Forms.Form
$form.Text = '${title}'
$form.Width = 460
$form.Height = 220
$form.StartPosition = 'CenterScreen'
$box = New-Object System.Windows.Forms.TextBox
$box.Dock = 'Fill'
$box.Multiline = $true
$form.Controls.Add($box)
$box.Add_KeyDown({
  param($sender, $event)
  if ($event.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
    [System.IO.File]::WriteAllText('${receivedFile.replaceAll('\\', '\\\\')}', $box.Text)
    # Freeze the fixture: a read-only TextBox has no blinking caret, so the
    # window becomes byte-stable and the deduplication check is deterministic.
    $box.ReadOnly = $true
  }
})
$form.Add_Shown({
  [System.IO.File]::WriteAllText('${readyFile.replaceAll('\\', '\\\\')}', "$PID" + [Environment]::NewLine + $form.Text)
  $box.Focus()
})
[System.Windows.Forms.Application]::Run($form)
`;
// Windows PowerShell reads a BOM-less script as ANSI, and this one carries CJK,
// so the BOM is load-bearing.
writeFileSync(windowScriptPath, `\uFEFF${windowScript}`, 'utf8');
// The window is started through Start-Process from a short launcher script: a
// PowerShell child spawned directly by Node (detached, no console) exits before
// it ever shows a window, while Start-Process reliably gets one on screen.
writeFileSync(launcherPath, `\uFEFFStart-Process -FilePath powershell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File','${windowScriptPath}')\n`, 'utf8');

let windowPid = null;
try {
	rmSync(receivedFile, { force: true });
	rmSync(readyFile, { force: true });
	const launched = spawnSync('powershell', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', launcherPath], { stdio: 'ignore' });
	check('the launcher exited cleanly', launched.status === 0, `status=${launched.status}`);

	for (let attempt = 0; attempt < 40 && !existsSync(readyFile); attempt += 1) await sleep(250);
	const ready = existsSync(readyFile) ? readFileSync(readyFile, 'utf8').split('\n') : [];
	windowPid = Number.parseInt(ready[0] ?? '', 10);
	check('the throwaway window came up', Number.isInteger(windowPid) && ready[1]?.trim() === title, existsSync(readyFile) ? `pid=${ready[0]}, title=${JSON.stringify(ready[1] ?? '')}` : 'no ready marker after 10s');

	// ── one call, three actions, one screenshot ─────────────────────────────
	const result = await sequence.execute({
		steps: [
			{ action: 'focus', title },
			{ action: 'type', text: typed },
			{ action: 'key', key: 'enter' }
		],
		risk: 'low',
		settleMs: 600
	}, exec);

	const ledger = result.steps.map((s) => `${s.action}${s.ok ? '' : `(${s.note ?? 'failed'})`}`).join(' -> ');
	check('all three steps ran', result.executed === 3 && result.failed === 0, `${result.executed}/${result.stepCount}, failed=${result.failed} :: ${ledger}`);
	check('the steps ran in order', result.steps.map((s) => s.action).join(',') === 'focus,type,key', result.steps.map((s) => s.action).join(','));
	check('focus reported the throwaway window as foreground', typeof result.steps[0].foregroundTitle === 'string' && result.steps[0].foregroundTitle.includes('dsh-pilot'), result.steps[0].foregroundTitle);
	check('each step reports its own duration', result.steps.every((s) => Number.isInteger(s.ms) && s.ms > 0), `${result.steps.map((s) => s.ms).join('/')} ms`);

	const frame = result.capture;
	check('the end frame exists', frame !== undefined && typeof frame.path === 'string' && existsSync(frame.path), frame === undefined ? 'none' : frame.path);
	check('the end frame is the foreground window, not the desktop', frame?.kind === 'window', String(frame?.kind));
	check('the end frame is window-sized', frame !== undefined && frame.imageWidth < 2000 && frame.imageHeight < 1200, `${frame?.imageWidth}x${frame?.imageHeight}`);
	check('the frame carries a content hash', typeof result.frameHash === 'string' && result.frameHash.length === 16, result.frameHash);
	check('exactly one screenshot was taken for three actions', attachments.length === 1, `${attachments.length} attachment(s)`);

	const violations = validateJsonSchemaValue(sequence.output.schema, result);
	check('the result matches the closed output schema', violations.length === 0, violations.slice(0, 3).join('; '));

	const blocks = sequence.output.render({}, result);
	check('render emits text plus the image', blocks.length === 2 && blocks[1].type === 'image', blocks.map((b) => b.type).join(','));
	check('render stays a compact ledger', blocks[0].text.includes('<steps>3/3 executed</steps>') && blocks[0].text.includes('action="focus"'), blocks[0].text.split('\n')[2]);

	await sleep(400);
	const received = existsSync(receivedFile) ? readFileSync(receivedFile, 'utf8') : null;
	check('the window received exactly the typed text', received === typed, JSON.stringify(received));

	// ── frame deduplication ────────────────────────────────────────────────
	// The fixture freezes itself once it has the text, so two captures of it are
	// byte-identical; `region` is not combined with `window` here because the
	// sensor treats an explicit window as the frame and ignores the crop.
	// A separate session is used so the first frame of this section is not itself
	// a duplicate of the batch frame above (the hash memory is per session).
	const execFresh = {
		...exec,
		agent: {
			...exec.agent,
			session: { ...exec.agent.session, header: { ...exec.agent.session.header, sessionId: 'sequence-smoke-dedup' } }
		}
	};
	attachments.length = 0;
	const stable = { window: title, settleMs: 300 };
	const first = await sequence.execute({ ...stable, steps: [{ action: 'wait', ms: 200 }] }, execFresh);
	const second = await sequence.execute({ ...stable, steps: [{ action: 'wait', ms: 200 }] }, execFresh);
	check('two consecutive frames of an unchanged area hash alike', first.frameHash === second.frameHash, `${first.frameHash} vs ${second.frameHash}`);
	check('the first frame is attached and the duplicate is not', first.capture?.image !== undefined && second.unchanged === true && second.capture?.image === undefined && attachments.length === 1, `unchanged=${second.unchanged}, attachments=${attachments.length}`);
	check('forceImage brings the duplicate back', (await sequence.execute({ ...stable, steps: [{ action: 'wait', ms: 50 }], forceImage: true }, execFresh)).capture?.image !== undefined);
} finally {
	if (Number.isInteger(windowPid)) {
		spawnSync('taskkill', ['/PID', String(windowPid), '/T', '/F'], { stdio: 'ignore' });
	}
	await sleep(300);
}

console.log(`\nsequence-smoke: ${failures === 0 ? 'OK' : `${failures} check(s) failed`}`);
process.exit(failures === 0 ? 0 : 1);
