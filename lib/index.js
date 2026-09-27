import z from '@deepseek-ai/schemastery';
import { defineTool } from '@deepseek-ai/dsh-tools';
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

/**
 * Real-time desktop vision and control for the DeepSeek Harness.
 *
 * Two model-facing tools share ONE pixel space. `screen_view` captures the live
 * desktop and returns the PNG as a real image block, so the calling model sees
 * the actual screen rather than a description of it. `desktop_control` drives
 * the mouse, keyboard, and windows in the physical pixels that image is
 * measured in, then optionally captures again, closing the see/act/see loop.
 *
 * Both halves run through PowerShell child processes:
 * `lib/scripts/desktop-probe.ps1` (sensor) and `lib/scripts/desktop-action.ps1`
 * (effector). Each child makes itself per-monitor DPI aware before it does
 * anything, which is what keeps the reported geometry honest: DPI-unaware
 * processes are lied to by Windows and would report a 2560x1600 panel as
 * 1707x1067, making every click land in the wrong place.
 *
 * @module dsh-pilot
 */

/** Stable Loader identity. */
const name = 'pilot';

/** Validated plugin configuration. */
const Config = z.object({
	/** How many screenshots to retain under the workspace capture directory. */
	captureRetention: z.number().default(30),
	/** Milliseconds allowed for one capture or one action before the child is killed. */
	timeoutMs: z.number().default(20000),
	/** Default settle delay between an action and its automatic capture. */
	settleMs: z.number().default(750),
	/** Per-step settle delay inside a desktop_sequence: enough for the UI to react, short enough to stay fast. */
	stepSettleMs: z.number().default(120),
	/** Hard cap on the steps one desktop_sequence call may run. */
	maxSequenceSteps: z.number().default(24),
	/** Also capture a frame when a tool result carries no image (still materializes the file). */
	alwaysSaveFile: z.boolean().default(true)
});

/** Services this plugin registers against. */
const inject = ['tools'];

/** Directory name for captured frames inside the session workspace. */
const CAPTURE_DIRNAME = '.dsh-pilot';

/**
 * Absolute path of this package, resolved from the module URL rather than the
 * working directory, so the helper scripts are found wherever the profile
 * mounted the package from.
 * @returns the package root directory.
 */
function packageRoot() {
	return dirname(dirname(fileURLToPath(import.meta.url)));
}

/** Path of the sensor script. */
function probeScript() {
	return join(packageRoot(), 'lib', 'scripts', 'desktop-probe.ps1');
}

/** Path of the effector script. */
function actionScript() {
	return join(packageRoot(), 'lib', 'scripts', 'desktop-action.ps1');
}

/** Scratch directory for parameter files and cancel tokens. */
function scratchDir() {
	const dir = join(resolve(process.env.TEMP ?? process.env.TMP ?? packageRoot()), 'dsh-pilot');
	mkdirSync(dir, { recursive: true });
	return dir;
}

let sequence = 0;

/** Unique-enough file stem for one invocation. */
function nextToken() {
	sequence += 1;
	return `${Date.now().toString(36)}-${process.pid.toString(36)}-${sequence.toString(36)}`;
}

/**
 * Run one PowerShell helper to completion.
 *
 * Parameters travel through a UTF-8 file rather than the command line, so
 * non-ASCII window titles and paths survive regardless of the console code
 * page. When the caller's signal aborts, the cancel token is stamped and the
 * child is killed, which is what makes an interrupted turn stop a gesture in
 * flight instead of letting the remaining clicks play out.
 *
 * @param script - absolute path of the helper script.
 * @param params - parameter object serialized as JSON for the child.
 * @param signal - the tool execution signal.
 * @param timeoutMs - hard kill deadline in milliseconds.
 * @returns the parsed JSON result object.
 */
function runHelper(script, params, signal, timeoutMs) {
	if (!existsSync(script)) throw new Error(`pilot: helper script is missing at ${script}`);
	const dir = scratchDir();
	const token = nextToken();
	const paramsPath = join(dir, `params-${token}.json`);
	const cancelPath = join(dir, `cancel-${token}.txt`);
	writeFileSync(paramsPath, JSON.stringify({ ...params, cancelFile: cancelPath }), 'utf8');

	return new Promise((resolvePromise, rejectPromise) => {
		const child = spawn(
			'powershell.exe',
			['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', script, '-ParamsPath', paramsPath],
			{ stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true }
		);
		let stdout = '';
		let stderr = '';
		let settled = false;
		let timer;

		const cleanup = () => {
			clearTimeout(timer);
			for (const file of [paramsPath, cancelPath]) {
				try {
					rmSync(file, { force: true });
				} catch {
					// A leftover scratch file is harmless.
				}
			}
		};

		const finish = (fn, value) => {
			if (settled) return;
			settled = true;
			cleanup();
			fn(value);
		};

		const abort = () => {
			try {
				writeFileSync(cancelPath, 'stop', 'utf8');
			} catch {
				// The kill below is the authoritative stop.
			}
			try {
				child.kill();
			} catch {
				// Already gone.
			}
			finish(rejectPromise, new Error('pilot: the action was cancelled before it completed'));
		};

		if (signal !== undefined) {
			if (signal.aborted) {
				finish(rejectPromise, new Error('pilot: the action was cancelled before it started'));
				return;
			}
			signal.addEventListener('abort', abort, { once: true });
		}

		timer = setTimeout(() => {
			try {
				child.kill();
			} catch {
				// Already gone.
			}
			finish(rejectPromise, new Error(`pilot: the helper did not finish within ${timeoutMs} ms`));
		}, timeoutMs);

		child.stdout.on('data', (chunk) => {
			stdout += chunk.toString('utf8');
		});
		child.stderr.on('data', (chunk) => {
			stderr += chunk.toString('utf8');
		});
		child.on('error', (error) => {
			finish(rejectPromise, new Error(`pilot: could not start PowerShell (${error.message})`));
		});
		child.on('close', (code) => {
			if (settled) return;
			signal?.removeEventListener('abort', abort);
			const payload = parseLastJson(stdout);
			if (payload === undefined) {
				const detail = stderr.trim().length > 0 ? stderr.trim() : `exit code ${code}`;
				finish(rejectPromise, new Error(`pilot: the helper produced no result (${detail})`));
				return;
			}
			if (payload.ok !== true) {
				finish(rejectPromise, new Error(String(payload.error ?? 'pilot: the helper reported a failure')));
				return;
			}
			finish(resolvePromise, payload);
		});
	});
}

/**
 * Read the last JSON object a helper printed. Helpers may emit assembly chatter
 * before their result, so the parse walks backwards line by line.
 * @param text - raw stdout.
 * @returns the parsed object, or undefined.
 */
function parseLastJson(text) {
	const lines = text.split(/\r?\n/u);
	for (let index = lines.length - 1; index >= 0; index -= 1) {
		const line = lines[index].trim();
		if (!line.startsWith('{') || !line.endsWith('}')) continue;
		try {
			return JSON.parse(line);
		} catch {
			// Keep looking further up.
		}
	}
	return undefined;
}

/** Options accepted by both helpers. */
function optionsFor(exec, config) {
	return {
		signal: exec.signal,
		timeoutMs: config.timeoutMs
	};
}

/**
 * Resolve (and create) the capture directory for one session.
 * @param exec - tool execution context.
 * @returns the absolute capture directory.
 */
function captureDir(exec) {
	const cwd = exec.agent?.session.header.cwd;
	const base = typeof cwd === 'string' && cwd.length > 0 ? cwd : scratchDir();
	const dir = join(base, CAPTURE_DIRNAME);
	mkdirSync(dir, { recursive: true });
	return dir;
}

/**
 * Delete the oldest frames beyond the retention limit. Attachments are stored
 * content-addressed elsewhere, so pruning a frame never breaks an image the
 * conversation already carries.
 * @param dir - capture directory.
 * @param retention - maximum frames to keep.
 */
function pruneCaptures(dir, retention) {
	if (!Number.isFinite(retention) || retention < 1) return;
	try {
		const entries = readdirSync(dir)
			.filter((entry) => entry.toLowerCase().endsWith('.png'))
			.map((entry) => {
				const full = join(dir, entry);
				try {
					return { full, mtime: statSync(full).mtimeMs };
				} catch {
					return undefined;
				}
			})
			.filter((entry) => entry !== undefined)
			.sort((left, right) => right.mtime - left.mtime);
		for (const entry of entries.slice(retention)) {
			try {
				rmSync(entry.full, { force: true });
			} catch {
				// A frame still open in a viewer stays until the next prune.
			}
		}
	} catch {
		// Pruning is housekeeping and never fails a capture.
	}
}

/** Capture parameters shared by both tools. */
function captureParams(args) {
	const params = { includeCursor: true };
	if (typeof args.screen === 'string' && args.screen.trim().length > 0) params.screen = args.screen.trim();
	if (typeof args.region === 'string' && args.region.trim().length > 0) params.region = args.region.trim();
	if (typeof args.window === 'string' && args.window.trim().length > 0) params.window = args.window.trim();
	if (args.includeCursor === false) params.includeCursor = false;
	return params;
}

/**
 * Perform one capture and, when an attachment store is mounted, commit the
 * frame as an image the conversation can carry.
 * @param ctx - plugin context.
 * @param exec - tool execution context.
 * @param config - validated plugin configuration.
 * @param args - the tool's capture arguments.
 * @returns the structured capture outcome.
 */
async function capture(ctx, exec, config, args) {
	const dir = captureDir(exec);
	const file = join(dir, `screen-${nextToken()}.png`);
	const options = optionsFor(exec, config);
	const probe = await runHelper(probeScript(), { ...captureParams(args), out: file }, options.signal, options.timeoutMs);
	pruneCaptures(dir, config.captureRetention);

	const result = {
		path: probe.path,
		kind: probe.kind,
		imageWidth: probe.imageWidth,
		imageHeight: probe.imageHeight,
		originX: probe.originX,
		originY: probe.originY,
		scale: probe.scale,
		screens: (probe.screens ?? []).map(screenEntryOf),
		cursor: probe.cursor,
		foregroundWindow: windowInfoOf(probe.foregroundWindow),
		...(probe.capturedAt === undefined ? {} : { capturedAt: probe.capturedAt })
	};

	// Frame deduplication, decided BEFORE the attachment is committed: a picture
	// identical to the one this session already received is not worth another
	// image block (nor a second copy in the store), unless the caller insists.
	const hash = frameHashOf(probe.path);
	if (hash !== undefined) {
		result.frameHash = hash;
		const key = exec?.agent?.session?.header?.sessionId ?? '__global__';
		const previous = lastFrameHashes.get(key);
		lastFrameHashes.set(key, hash);
		if (previous === hash && args.forceImage !== true) {
			result.unchanged = true;
			result.imageSkipped = 'identical to the previous frame of this session, so it was not attached again; pass forceImage: true to see it anyway';
			return result;
		}
	}

	const attachments = ctx.get('attachments');
	if (attachments === undefined || !config.alwaysSaveFile && args.withImage === false) return result;

	const limits = attachments.imageLimits;
	const bytes = readFileSync(probe.path);
	if (bytes.byteLength > Math.min(limits.maxImageBytes, limits.maxMessageImageBytes)) {
		result.imageError = `the frame is ${bytes.byteLength} bytes, above this deployment's per-image limit; narrow it with a region or a window capture`;
		return result;
	}

	try {
		const ref = await attachments.saveImage({ data: new Uint8Array(bytes), mediaType: 'image/png', name: `screen-${nextToken()}.png` });
		result.image = {
			attachmentId: ref.attachmentId,
			mediaType: ref.mediaType,
			bytes: ref.bytes,
			width: ref.width,
			height: ref.height,
			...(ref.name === undefined ? {} : { name: ref.name }),
			...(ref.originalDimensions === undefined ? {} : { originalDimensions: { ...ref.originalDimensions } })
		};
	} catch (error) {
		result.imageError = `the frame could not be attached: ${error instanceof Error ? error.message : String(error)}`;
	}
	return result;
}

/** Enforce the image-input capability gate for the calling route. */
async function assertImageCapableRoute(ctx, exec, what) {
	const routed = exec.agent?.session.requestHeader()?.config;
	const provider = routed?.provider ?? exec.agent?.options.provider;
	const model = routed?.model ?? exec.agent?.options.model;
	const llm = ctx.get('llm');
	if (provider === undefined || model === undefined || llm === undefined) {
		throw new Error(`${what} needs an image-capable model route, and the current route could not be resolved; switch to a model that accepts image input`);
	}
	const active = await llm.resolveModelInfo(provider, model, exec.signal);
	if (active.inputModalities === undefined || !active.inputModalities.includes('image')) {
		throw new Error(`${what} needs a model that accepts image input, but "${model}" does not declare it; switch models to see the screen`);
	}
}

/** Render one capture as the model-facing envelope plus its image block. */
function captureContent(value) {
	const screens = Array.isArray(value.screens) && value.screens.length > 0
		? value.screens.map((screen) => `${screen.primary ? 'primary ' : ''}${screen.device} ${screen.bounds}`).join('; ')
		: 'unknown';
	const cursor = value.cursor === null || value.cursor === undefined
		? 'unavailable'
		: `${value.cursor.x},${value.cursor.y}`;
	const foreground = value.foregroundWindow === null || value.foregroundWindow === undefined
		? 'none'
		: `"${value.foregroundWindow.title}" (${value.foregroundWindow.process}, class ${value.foregroundWindow.class}) at ${value.foregroundWindow.bounds}`;
	const lines = [
		'<screen_capture>',
		`<kind>${value.kind}</kind>`,
		`<image_size>${value.imageWidth}x${value.imageHeight}</image_size>`,
		`<physical_origin>${value.originX},${value.originY}</physical_origin>`,
		`<scale>${value.scale}</scale>`,
		`<screens>${screens}</screens>`,
		`<cursor>${cursor}</cursor>`,
		`<foreground_window>${foreground}</foreground_window>`,
		`<file>${value.path}</file>`
	];
	if (value.imageError !== undefined) lines.push(`<image_error>${value.imageError}</image_error>`);
	if (value.imageSkipped !== undefined) lines.push(`<image_skipped>${value.imageSkipped}</image_skipped>`);
	lines.push('</screen_capture>');
	if (value.image !== undefined) lines.push(COORDINATE_CONTRACT);
	else if (value.unchanged === true) lines.push('Nothing changed since the last frame of this session, so the image you already have still applies — including its coordinates.');
	const blocks = [{ type: 'text', text: lines.join('\n') }];
	if (value.image !== undefined) blocks.push({ type: 'image', attachment: value.image });
	return blocks;
}

/** The pixel-space contract, restated next to every frame the model receives. */
const COORDINATE_CONTRACT = [
	'Image pixel (0,0) is the top-left of this frame. Because both halves of this device are per-monitor DPI aware, one image pixel is one real screen pixel:',
	'to act on a feature at image (x,y), call desktop_control with exactly x and y. Do not rescale for display scaling.'
].join(' ');

/** Render one control outcome. */
function controlText(value) {
	const cursor = value.cursor === null || value.cursor === undefined ? 'unknown' : `${value.cursor.x},${value.cursor.y}`;
	const lines = [
		'<desktop_action>',
		`<action>${value.action}</action>`,
		`<cursor>${cursor}</cursor>`,
		`<foreground>${value.foregroundTitle ?? 'unknown'}${value.foregroundProcess === undefined || value.foregroundProcess === null ? '' : ` (${value.foregroundProcess})`}</foreground>`
	];
	if (Array.isArray(value.notes)) for (const note of value.notes) lines.push(`<note>${note}</note>`);
	if (typeof value.capturePath === 'string') lines.push(`<capture_file>${value.capturePath}</capture_file>`);
	if (typeof value.captureError === 'string') lines.push(`<capture_error>${value.captureError}</capture_error>`);
	lines.push('</desktop_action>');
	if (value.capture !== null && value.capture !== undefined) lines.push(COORDINATE_CONTRACT);
	return lines.join('\n');
}

const IMAGE_VALUE_SCHEMA = {
	type: 'object',
	additionalProperties: false,
	properties: {
		attachmentId: { type: 'string', required: true },
		mediaType: { type: 'string', required: true },
		bytes: { type: 'integer', required: true },
		width: { type: 'integer', required: true },
		height: { type: 'integer', required: true },
		name: { type: 'string' },
		originalDimensions: {
			type: 'object',
			additionalProperties: false,
			properties: {
				width: { type: 'integer', required: true },
				height: { type: 'integer', required: true }
			}
		}
	}
};

const SCREEN_INFO_SCHEMA = {
	type: 'object',
	additionalProperties: false,
	properties: {
		device: { type: 'string', required: true },
		primary: { type: 'boolean', required: true },
		bounds: { type: 'string', required: true }
	}
};

const WINDOW_INFO_SCHEMA = {
	type: 'object',
	additionalProperties: false,
	properties: {
		handle: { type: 'string' },
		title: { type: 'string' },
		class: { type: 'string' },
		process: { type: 'string' },
		pid: { type: 'integer' },
		bounds: { type: 'string' },
		minimized: { type: 'boolean' },
		foreground: { type: 'boolean' }
	}
};

/**
 * Copy the screen-inventory entry field by field. The sensor's own bookkeeping
 * keys must never reach a closed output schema: a result carrying an undeclared
 * key is rejected by the runtime *after* the side effect has already happened.
 * @param screen - one entry from the sensor's `screens` array.
 * @returns the declared projection.
 */
function screenEntryOf(screen) {
	return { device: screen.device, primary: screen.primary, bounds: screen.bounds };
}

/**
 * Copy a window entry field by field, dropping the sensor's undeclared keys.
 * @param window - a sensor window entry, or undefined.
 * @returns the declared projection, or undefined when there was no window.
 */
function windowInfoOf(window) {
	if (window === null || window === undefined) return undefined;
	return {
		handle: window.handle,
		title: window.title,
		class: window.class,
		process: window.process,
		pid: window.pid,
		bounds: window.bounds,
		...(window.minimized === undefined ? {} : { minimized: window.minimized }),
		...(window.foreground === undefined ? {} : { foreground: window.foreground })
	};
}

const CAPTURE_SCHEMA = {
	type: 'object',
	additionalProperties: false,
	properties: {
		path: { type: 'string', required: true },
		kind: { type: 'string', required: true },
		imageWidth: { type: 'integer', required: true },
		imageHeight: { type: 'integer', required: true },
		originX: { type: 'integer', required: true },
		originY: { type: 'integer', required: true },
		scale: { type: 'number', required: true },
		screens: { type: 'array', required: true, items: SCREEN_INFO_SCHEMA },
		cursor: {
			type: 'object',
			additionalProperties: false,
			properties: {
				x: { type: 'integer', required: true },
				y: { type: 'integer', required: true },
				screen: { type: 'string' }
			}
		},
		foregroundWindow: WINDOW_INFO_SCHEMA,
		image: IMAGE_VALUE_SCHEMA,
		imageError: { type: 'string' },
		imageSkipped: { type: 'string' },
		frameHash: { type: 'string' },
		unchanged: { type: 'boolean' },
		capturedAt: { type: 'string' }
	}
};

/** Cursor projection shared by the capture and control schemas. */
const CURSOR_SCHEMA = {
	type: 'object',
	additionalProperties: false,
	properties: {
		x: { type: 'integer', required: true },
		y: { type: 'integer', required: true },
		screen: { type: 'string' }
	}
};

/** Actions a sequence step may name. `wait` is served in this process. */
const SEQUENCE_ACTIONS = ['click', 'doubleClick', 'rightClick', 'middleClick', 'move', 'drag', 'scroll', 'type', 'key', 'focus', 'wait'];
/** Actions whose x/y are mandatory. */
const POINTER_ACTIONS = new Set(['click', 'doubleClick', 'rightClick', 'middleClick', 'move', 'scroll']);
/** The risk ladder the batch gate enforces. */
const RISKS = ['low', 'medium', 'high'];
const RISK_ORDER = { low: 0, medium: 1, high: 2 };
/** Step fields forwarded verbatim to the action helper. */
const STEP_FIELDS = ['x', 'y', 'toX', 'toY', 'amount', 'text', 'key', 'title', 'button'];

const SEQUENCE_STEP_RESULT_SCHEMA = {
	type: 'object',
	additionalProperties: false,
	properties: {
		index: { type: 'integer', required: true },
		action: { type: 'string', required: true },
		ok: { type: 'boolean', required: true },
		ms: { type: 'integer', required: true },
		cursor: CURSOR_SCHEMA,
		foregroundTitle: { type: 'string' },
		note: { type: 'string' },
		risk: { type: 'string' }
	}
};

const SEQUENCE_SCHEMA = {
	type: 'object',
	additionalProperties: false,
	properties: {
		risk: { type: 'string', required: true },
		confirmed: { type: 'boolean', required: true },
		planned: { type: 'boolean' },
		stepCount: { type: 'integer', required: true },
		executed: { type: 'integer', required: true },
		failed: { type: 'integer', required: true },
		steps: { type: 'array', required: true, items: SEQUENCE_STEP_RESULT_SCHEMA },
		cursor: CURSOR_SCHEMA,
		foregroundTitle: { type: 'string' },
		foregroundProcess: { type: 'string' },
		capture: CAPTURE_SCHEMA,
		capturePath: { type: 'string' },
		captureError: { type: 'string' },
		frameHash: { type: 'string' },
		unchanged: { type: 'boolean' },
		imageSkipped: { type: 'string' },
		notes: { type: 'array', items: { type: 'string' } },
		actedAt: { type: 'string' }
	}
};

/**
 * Validate and normalize one batch of steps. A step is a desktop_control action
 * without its own screenshot, plus optional per-step `settleMs`, `risk` and
 * `riskNote`; the `wait` action takes `ms` instead.
 *
 * This runs before anything touches the desktop, so a malformed batch costs one
 * round trip instead of half a gesture.
 *
 * @param args - the tool arguments.
 * @param config - validated plugin configuration (for the step cap).
 * @returns the normalized steps.
 */
function normalizeSequence(args, config) {
	const raw = Array.isArray(args?.steps) ? args.steps : [];
	if (raw.length === 0) throw new Error('desktop_sequence needs at least one step');
	if (raw.length > config.maxSequenceSteps) {
		throw new Error(`desktop_sequence accepts at most ${config.maxSequenceSteps} steps (got ${raw.length}); split the batch or raise maxSequenceSteps`);
	}
	return raw.map((step, offset) => {
		const position = offset + 1;
		if (step === null || typeof step !== 'object' || Array.isArray(step)) throw new Error(`step ${position} must be an object`);
		const action = step.action;
		if (typeof action !== 'string' || !SEQUENCE_ACTIONS.includes(action)) {
			throw new Error(`step ${position} has an unknown action ${JSON.stringify(action)}; use ${SEQUENCE_ACTIONS.join('/')}`);
		}
		const normalized = { action };
		for (const field of [...STEP_FIELDS, 'ms', 'risk', 'riskNote']) {
			if (step[field] !== undefined && step[field] !== null) normalized[field] = step[field];
		}
		if (POINTER_ACTIONS.has(action) && (!Number.isInteger(normalized.x) || !Number.isInteger(normalized.y))) {
			throw new Error(`step ${position} (${action}) needs integer x and y`);
		}
		if (action === 'drag' && (!Number.isInteger(normalized.toX) || !Number.isInteger(normalized.toY))) {
			throw new Error(`step ${position} (drag) needs integer toX and toY`);
		}
		if (action === 'type' && typeof normalized.text !== 'string') throw new Error(`step ${position} (type) needs text`);
		if (action === 'key' && typeof normalized.key !== 'string') throw new Error(`step ${position} (key) needs key`);
		if (action === 'focus' && typeof normalized.title !== 'string') throw new Error(`step ${position} (focus) needs title`);
		if (action === 'wait' && !Number.isInteger(normalized.ms)) throw new Error(`step ${position} (wait) needs integer ms`);
		if (normalized.risk !== undefined && !RISKS.includes(normalized.risk)) {
			throw new Error(`step ${position} risk must be one of ${RISKS.join('/')}`);
		}
		return normalized;
	});
}

/**
 * Apply the risk gate: the model declares risk, the tool enforces it. Low risk
 * batches freely; medium/high is refused before anything is executed unless the
 * caller passes `confirm: true` (which it does only after the user agreed).
 *
 * @param steps - normalized steps.
 * @param declared - the batch-level risk the model declared.
 * @param confirm - the caller's explicit approval flag.
 * @returns the effective risk level.
 */
function sequenceRisk(steps, declared, confirm) {
	let effective = RISKS.includes(declared) ? declared : 'low';
	const flagged = [];
	for (const [offset, step] of steps.entries()) {
		const stepRisk = step.risk ?? 'low';
		if (RISK_ORDER[stepRisk] > 0) {
			const why = typeof step.riskNote === 'string' && step.riskNote.length > 0 ? ` (${step.riskNote})` : '';
			flagged.push(`#${offset + 1} ${step.action}${why}`);
		}
		if (RISK_ORDER[stepRisk] > RISK_ORDER[effective]) effective = stepRisk;
	}
	if (RISK_ORDER[effective] > 0 && confirm !== true) {
		const parts = flagged.length > 0 ? flagged.join(', ') : 'the batch as a whole';
		throw new Error(
			`desktop_sequence refused before touching the desktop: this batch is declared ${effective} risk (${parts}). ` +
			'Show the user what it will do, then re-issue the same steps with confirm: true — or run the risky step on its own so it can be reviewed alone.'
		);
	}
	return effective;
}

/** A wait that still honours an interrupted turn. */
function abortableWait(ms, signal) {
	return new Promise((resolvePromise, rejectPromise) => {
		const timer = setTimeout(resolvePromise, Math.max(0, ms));
		signal?.addEventListener('abort', () => {
			clearTimeout(timer);
			rejectPromise(new Error('pilot: the batch was cancelled during a wait'));
		}, { once: true });
	});
}

/** Run one step: `wait` locally, everything else through the action helper. */
async function runSequenceStep(step, config, options) {
	const started = Date.now();
	if (step.action === 'wait') {
		await abortableWait(step.ms, options.signal);
		return { action: 'wait', ok: true, ms: Date.now() - started };
	}
	const params = { action: step.action, settleMs: Number.isSafeInteger(step.settleMs) ? step.settleMs : config.stepSettleMs };
	for (const field of STEP_FIELDS) if (step[field] !== undefined) params[field] = step[field];
	const acted = await runHelper(actionScript(), params, options.signal, options.timeoutMs);
	const entry = { action: step.action, ok: true, ms: Date.now() - started };
	if (acted.cursor !== undefined) entry.cursor = acted.cursor;
	if (acted.foregroundTitle !== undefined) entry.foregroundTitle = acted.foregroundTitle;
	if (Array.isArray(acted.notes) && acted.notes.length > 0) entry.note = acted.notes.join('; ');
	return entry;
}

/** Content hash of one saved frame: identifies a screen that did not change. */
function frameHashOf(file) {
	try {
		return createHash('sha256').update(readFileSync(file)).digest('hex').slice(0, 16);
	} catch {
		return undefined;
	}
}

/** Last frame hash per session, so an identical frame can be recognised. */
const lastFrameHashes = new Map();

/** Render one batch outcome: a compact per-step ledger, then the end frame. */
function sequenceText(value) {
	const flags = `${value.risk}${value.confirmed === true ? ', confirmed' : ''}${value.planned === true ? ', dry run' : ''}`;
	const lines = [
		'<desktop_sequence>',
		`<risk>${flags}</risk>`,
		`<steps>${value.executed}/${value.stepCount} executed${value.failed > 0 ? `, ${value.failed} failed` : ''}</steps>`
	];
	for (const step of value.steps ?? []) {
		lines.push(`<step n="${step.index}" action="${step.action}" ok="${step.ok}" ms="${step.ms}">${step.note === undefined ? '' : step.note}</step>`);
	}
	if (value.foregroundTitle !== undefined) {
		lines.push(`<foreground>${value.foregroundTitle}${value.foregroundProcess === undefined ? '' : ` (${value.foregroundProcess})`}</foreground>`);
	}
	if (value.cursor !== undefined && value.cursor !== null) lines.push(`<cursor>${value.cursor.x},${value.cursor.y}</cursor>`);
	if (typeof value.capturePath === 'string') lines.push(`<capture_file>${value.capturePath}</capture_file>`);
	if (typeof value.frameHash === 'string') lines.push(`<frame_hash>${value.frameHash}${value.unchanged === true ? ' (unchanged)' : ''}</frame_hash>`);
	if (typeof value.imageSkipped === 'string') lines.push(`<image_skipped>${value.imageSkipped}</image_skipped>`);
	if (typeof value.captureError === 'string') lines.push(`<capture_error>${value.captureError}</capture_error>`);
	for (const note of value.notes ?? []) lines.push(`<note>${note}</note>`);
	lines.push('</desktop_sequence>');
	if (value.capture !== undefined && value.capture !== null) lines.push(COORDINATE_CONTRACT);
	const blocks = [{ type: 'text', text: lines.join('\n') }];
	const image = value.capture === undefined || value.capture === null ? undefined : value.capture.image;
	if (image !== undefined) blocks.push({ type: 'image', attachment: image });
	return blocks;
}

/**
 * Register `screen_view`, `desktop_control` and `desktop_sequence`.
 * @param ctx - the plugin context owning the tool registry.
 * @param config - validated plugin configuration.
 */
function apply(ctx, config) {
	for (const key of ['captureRetention', 'timeoutMs', 'settleMs', 'stepSettleMs', 'maxSequenceSteps']) {
		const value = config[key];
		if (typeof value !== 'number' || !Number.isFinite(value) || value <= 0) throw new Error(`pilot: config ${key} must be a positive number`);
	}

	ctx.tools.register(defineTool({
		name: 'screen_view',
		description: [
			'See the live desktop: capture the screen and return the actual image, so you can read what is on it instead of guessing.',
			'Use this before any desktop_control action, and again after acting, to confirm the result.',
			'The frame is per-monitor DPI aware: one image pixel equals one real screen pixel, so coordinates you read off the image are exactly the x/y that desktop_control consumes.',
			'Defaults to the primary monitor; pass window to frame one app, screen "all" to composite every monitor, or region for a crop.',
			'Requires the current model to accept image input.'
		].join(' '),
		parameters: {
			screen: {
				type: 'string',
				description: "Which monitor: 'primary' (default), 'all' for the whole virtual desktop, or a 0-based monitor index."
			},
			window: {
				type: 'string',
				description: 'Case-insensitive substring of a window title or process name; frames that window instead of a monitor.'
			},
			region: {
				type: 'string',
				description: "Crop in physical screen pixels as 'x,y,width,height', relative to the captured area's top-left."
			},
			includeCursor: {
				type: 'boolean',
				description: 'Draw a crosshair at the pointer (default true) so you can see where it is.'
			},
			forceImage: {
				type: 'boolean',
				description: 'Attach the frame even when it is pixel-identical to the previous frame of this session (default: such a duplicate is reported as unchanged and not attached).'
			}
		},
		output: {
			schema: CAPTURE_SCHEMA,
			render: (_args, value) => captureContent(value),
			presentationMeta: (_args, value) => ({ path: value.path })
		},
		isConcurrencySafe: () => true,
		async execute(args, exec) {
			await assertImageCapableRoute(ctx, exec, 'screen_view');
			const value = await capture(ctx, exec, config, { ...args, forceImage: args.forceImage === true });
			if (value.image === undefined && value.imageSkipped === undefined) {
				throw new Error(`screen_view could not attach the frame${value.imageError === undefined ? '' : `: ${value.imageError}`}`);
			}
			return value;
		},
		presentCall(args) {
			return {
				card: 'generic',
				title: args.window === undefined ? 'View screen' : `View window ${args.window}`,
				kind: 'read'
			};
		}
	}));

	ctx.tools.register(defineTool({
		name: 'desktop_control',
		description: [
			'Operate the live desktop: move the pointer, click, drag, scroll, type text, send keys, focus a window, or list windows.',
			'Coordinates are physical screen pixels and match screen_view images exactly, so read the target off a fresh screenshot and reuse those pixels verbatim.',
			'Each press, keystroke, and window focus goes to whatever is focused on the real desktop, so call screen_view first and re-check after acting when the result matters.',
			'Set capture true to receive a fresh image in the same result, which shows the effect of the action without a second round trip.',
			'Text arrives as a single paste, so applications see one insertion rather than per-character typing.'
		].join(' '),
		parameters: {
			action: {
				type: 'string',
				required: true,
				enum: ['click', 'doubleClick', 'rightClick', 'middleClick', 'move', 'drag', 'scroll', 'type', 'key', 'focus', 'windows'],
				description: 'click | doubleClick | rightClick | middleClick | move | drag | scroll | type | key | focus | windows.'
			},
			x: { type: 'integer', description: 'Target x in physical screen pixels; required for the pointer actions and for scroll-at-a-point.' },
			y: { type: 'integer', description: 'Target y in physical screen pixels; required for the pointer actions and for scroll-at-a-point.' },
			toX: { type: 'integer', description: 'drag end x, or a nonzero value to make scroll horizontal.' },
			toY: { type: 'integer', description: 'drag end y, or a nonzero value to make scroll horizontal.' },
			text: { type: 'string', description: 'Text to insert for the type action.' },
			key: { type: 'string', description: "Key for the key action: a single character, 'enter', 'tab', 'esc', 'f5', or a chord such as 'ctrl+s' or 'alt+tab'." },
			amount: { type: 'integer', description: 'Wheel notches for scroll; positive scrolls up, negative down. Default 3.' },
			button: {
				type: 'string',
				enum: ['left', 'right', 'middle'],
				description: 'Mouse button for click, doubleClick, and drag. Default left.'
			},
			title: {
				type: 'string',
				description: 'Case-insensitive window title or process substring; required by focus, and filters windows.'
			},
			capture: {
				type: 'boolean',
				description: 'Capture a fresh frame after the action and show it in this result. Default true.'
			},
			settleMs: {
				type: 'integer',
				description: 'Milliseconds to wait before the automatic capture, so the screen can repaint. Default 750.'
			},
			forceImage: {
				type: 'boolean',
				description: 'Attach the frame even when the screen is pixel-identical to the previous one (default: such a duplicate is not attached again).'
			}
		},
		output: {
			schema: {
				type: 'object',
				additionalProperties: false,
				properties: {
					action: { type: 'string', required: true },
					cursor: {
						type: 'object',
						additionalProperties: false,
						properties: {
							x: { type: 'integer', required: true },
							y: { type: 'integer', required: true },
							screen: { type: 'string' }
						}
					},
					foregroundTitle: { type: 'string' },
					foregroundClass: { type: 'string' },
					foregroundProcess: { type: 'string' },
					notes: { type: 'array', items: { type: 'string' } },
					windows: { type: 'array', items: WINDOW_INFO_SCHEMA },
					windowCount: { type: 'integer' },
					actedAt: { type: 'string' },
					capture: CAPTURE_SCHEMA,
					capturePath: { type: 'string' },
					captureError: { type: 'string' },
					frameHash: { type: 'string' },
					unchanged: { type: 'boolean' },
					imageSkipped: { type: 'string' }
				}
			},
			render: (_args, value) => {
				const blocks = [{ type: 'text', text: controlText(value) }];
				if (value.capture !== null && value.capture !== undefined && value.capture.image !== undefined) {
					blocks.push({ type: 'image', attachment: value.capture.image });
				}
				return blocks;
			}
		},
		isConcurrencySafe: () => false,
		async execute(args, exec) {
			const wantsCapture = args.capture !== false;
			if (wantsCapture) await assertImageCapableRoute(ctx, exec, 'desktop_control with capture');

			const settle = Number.isSafeInteger(args.settleMs) ? args.settleMs : config.settleMs;
			const params = { action: args.action, settleMs: settle };
			for (const field of ['x', 'y', 'toX', 'toY', 'amount', 'text', 'key', 'title', 'button']) {
				if (args[field] !== undefined && args[field] !== null) params[field] = args[field];
			}

			const options = optionsFor(exec, config);
			const acted = await runHelper(actionScript(), params, options.signal, options.timeoutMs);
			// Copy the declared fields only: the helper's own bookkeeping keys
			// must not reach the closed output schema.
			const value = { action: args.action };
			for (const field of ['cursor', 'foregroundTitle', 'foregroundClass', 'foregroundProcess', 'notes', 'windows', 'windowCount', 'actedAt']) {
				if (acted[field] !== undefined) value[field] = acted[field];
			}

			if (wantsCapture) {
				try {
					const frame = await capture(ctx, exec, config, { includeCursor: true, forceImage: args.forceImage === true });
					value.capture = frame;
					value.capturePath = frame.path;
					if (frame.frameHash !== undefined) value.frameHash = frame.frameHash;
					if (frame.unchanged !== undefined) value.unchanged = frame.unchanged;
					if (frame.imageSkipped !== undefined) value.imageSkipped = frame.imageSkipped;
					if (frame.image === undefined && frame.imageError !== undefined) value.captureError = frame.imageError;
				} catch (error) {
					value.captureError = error instanceof Error ? error.message : String(error);
				}
			}
			return value;
		},
		presentCall(args) {
			return {
				card: 'generic',
				title: `Desktop ${args.action}${args.title === undefined ? '' : ` ${args.title}`}`,
				kind: 'execute'
			};
		}
	}));

	ctx.tools.register(defineTool({
		name: 'desktop_sequence',
		description: [
			'Run several desktop actions in ONE call: focus, click, type, key, scroll … then look once at the end.',
			'This is the fast path. Calling desktop_control once per action costs one model round trip and one screenshot per action; a batch costs one round trip and, by default, a single frame — that difference, not the click speed, is what makes desktop work feel quick.',
			'Each step is a desktop_control action without its own screenshot, and steps run in order. By default the batch stops at the first failure, so a refused focus can never be followed by typing into the wrong window.',
			'After the last step the result carries one frame — by default of the window that was foreground during the batch, not the whole desktop — plus a frame_hash. When that hash matches the previous frame the image is not attached again; pass forceImage: true to see it anyway.',
			'Declare risk honestly: "low" (default) batches freely; a batch that is medium/high — at the batch level or on any step — is refused unless you pass confirm: true, which you do only after the user has agreed. dryRun: true validates the batch and lists the plan without touching the desktop.',
			'Batch the low-risk steps of a task and verify once at the end; only stop to screenshot in the middle when the UI state is genuinely uncertain.'
		].join(' '),
		parameters: {
			steps: {
				type: 'array',
				required: true,
				description: 'Ordered steps. Each object is one desktop_control action: {action, x, y, toX, toY, text, key, title, amount, button, settleMs, risk, riskNote}; action "wait" takes ms. Coordinates are physical screen pixels.'
			},
			risk: {
				type: 'string',
				enum: RISKS,
				description: 'Risk you declare for the whole batch (default low). medium/high requires confirm: true.'
			},
			confirm: {
				type: 'boolean',
				description: 'Explicit approval for a medium/high-risk batch. Without it the tool refuses before touching the desktop.'
			},
			dryRun: {
				type: 'boolean',
				description: 'Validate the batch and list the plan without executing anything.'
			},
			capture: {
				type: 'string',
				enum: ['end', 'none'],
				description: "end (default) captures one frame after the last step; none skips the frame entirely."
			},
			target: {
				type: 'string',
				enum: ['window', 'screen', 'all'],
				description: "What the end frame shows: window (default) = the window that was foreground during the batch, screen = the primary monitor, all = the whole virtual desktop."
			},
			window: {
				type: 'string',
				description: 'Frame this window instead (case-insensitive title or process substring), overriding target.'
			},
			region: {
				type: 'string',
				description: "Crop the end frame in physical pixels as 'x,y,width,height'."
			},
			forceImage: {
				type: 'boolean',
				description: 'Attach the end frame even when it is pixel-identical to the previous frame.'
			},
			stopOnError: {
				type: 'boolean',
				description: 'Stop at the first failing step (default true); false keeps going and reports every failure.'
			},
			settleMs: {
				type: 'integer',
				description: 'Delay before the end capture so the screen can repaint (default: the configured settleMs).'
			}
		},
		output: {
			schema: SEQUENCE_SCHEMA,
			render: (_args, value) => sequenceText(value),
			presentationMeta: (_args, value) => ({ path: value.capturePath })
		},
		isConcurrencySafe: () => false,
		async execute(args, exec) {
			const steps = normalizeSequence(args, config);
			const risk = sequenceRisk(steps, args.risk, args.confirm);
			const confirmed = args.confirm === true;

			if (args.dryRun === true) {
				return {
					risk,
					confirmed,
					planned: true,
					stepCount: steps.length,
					executed: 0,
					failed: 0,
					steps: steps.map((step, offset) => ({
						index: offset + 1,
						action: step.action,
						ok: true,
						ms: 0,
						...(step.risk === undefined ? {} : { risk: step.risk }),
						...(typeof step.riskNote === 'string' ? { note: step.riskNote } : {})
					})),
					notes: ['dry run: nothing was executed']
				};
			}

			const wantsFrame = args.capture !== 'none';
			if (wantsFrame) await assertImageCapableRoute(ctx, exec, 'desktop_sequence with capture');
			const options = optionsFor(exec, config);
			const stopOnError = args.stopOnError !== false;
			const results = [];
			let failed = 0;

			for (const [offset, step] of steps.entries()) {
				if (exec?.signal?.aborted) throw new Error('desktop_sequence: the batch was cancelled');
				const stepStarted = Date.now();
				try {
					const entry = await runSequenceStep(step, config, options);
					results.push({ index: offset + 1, ...entry, ...(step.risk === undefined ? {} : { risk: step.risk }) });
				} catch (error) {
					failed += 1;
					results.push({
						index: offset + 1,
						action: step.action,
						ok: false,
						ms: Date.now() - stepStarted,
						note: error instanceof Error ? error.message : String(error),
						...(step.risk === undefined ? {} : { risk: step.risk })
					});
					if (stopOnError) break;
				}
			}

			const value = {
				risk,
				confirmed,
				planned: false,
				stepCount: steps.length,
				executed: results.filter((entry) => entry.ok).length,
				failed,
				steps: results,
				actedAt: new Date().toISOString()
			};
			const lastCursor = [...results].reverse().find((entry) => entry.cursor !== undefined);
			if (lastCursor !== undefined) value.cursor = lastCursor.cursor;
			const lastForeground = [...results].reverse().find((entry) => entry.foregroundTitle !== undefined);
			if (lastForeground !== undefined) value.foregroundTitle = lastForeground.foregroundTitle;

			if (wantsFrame) {
				try {
					await abortableWait(Number.isSafeInteger(args.settleMs) ? args.settleMs : config.settleMs, exec?.signal);
					const captureArgs = { includeCursor: false };
					if (typeof args.window === 'string' && args.window.trim().length > 0) captureArgs.window = args.window.trim();
					else if (args.target === 'all') captureArgs.screen = 'all';
					else if (args.target === 'screen') captureArgs.screen = 'primary';
					else if (typeof value.foregroundTitle === 'string' && value.foregroundTitle.length > 0) captureArgs.window = value.foregroundTitle;
					else captureArgs.screen = 'primary';
					if (typeof args.region === 'string' && args.region.trim().length > 0) captureArgs.region = args.region.trim();
					const frame = await capture(ctx, exec, config, { ...captureArgs, forceImage: args.forceImage === true });
					value.capture = frame;
					value.capturePath = frame.path;
					if (frame.frameHash !== undefined) value.frameHash = frame.frameHash;
					if (frame.unchanged !== undefined) value.unchanged = frame.unchanged;
					if (frame.imageSkipped !== undefined) value.imageSkipped = frame.imageSkipped;
					if (frame.image === undefined && frame.imageError !== undefined) value.captureError = frame.imageError;
				} catch (error) {
					value.captureError = error instanceof Error ? error.message : String(error);
				}
			}
			return value;
		},
		presentCall(args) {
			const count = Array.isArray(args?.steps) ? args.steps.length : 0;
			return {
				card: 'generic',
				title: `Desktop batch (${count} step${count === 1 ? '' : 's'})`,
				kind: 'execute'
			};
		}
	}));
}

export { Config, apply, inject, name };
