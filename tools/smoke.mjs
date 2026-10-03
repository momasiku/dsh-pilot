// Load-time smoke test for the plugin's host half.
//
// Imports the real @deepseek-ai/dsh-tools + schemastery from the DSH app
// checkout, then drives apply() with a stub context. This catches schema-DSL
// violations, missing services, render-block mistakes, and — via the validator
// below — tool results whose shape does not match the closed output schema the
// runtime enforces. That last check exists because a result carrying an
// undeclared key is rejected only after the side effect already happened.
//
// Usage: node tools/smoke.mjs "D:\\AGAENT\\DSH Desktop\\resources\\app"

const appRoot = process.argv[2];
if (appRoot === undefined) {
	console.error('usage: node tools/smoke.mjs <app-root>');
	process.exit(2);
}

const appBase = `file:///${appRoot.replaceAll('\\', '/')}/`;
await import(new URL('node_modules/@deepseek-ai/dsh-tools/lib/index.js', appBase).href);
const { Config, apply, inject, name } = await import(new URL('../lib/index.js', import.meta.url).href);

console.log(`plugin name: ${name}`);
console.log(`inject: ${JSON.stringify(inject)}`);

const registered = new Map();
const ctx = {
	tools: {
		register(tool) {
			if (registered.has(tool.name)) throw new Error(`duplicate tool ${tool.name}`);
			registered.set(tool.name, tool);
		}
	},
	get(service) {
		if (service === 'attachments') {
			return {
				imageLimits: { maxImageBytes: 8 * 1024 * 1024, maxMessageImageBytes: 8 * 1024 * 1024, mediaTypes: ['image/png', 'image/jpeg', 'image/webp', 'image/gif'], maxImagesPerMessage: 8, maxImageDimension: 8192, maxImagePixels: 50_000_000 },
				async saveImage(input) {
					return { attachmentId: 'sha256:stub', mediaType: input.mediaType, bytes: input.data.byteLength, width: 100, height: 100, name: input.name };
				}
			};
		}
		if (service === 'llm') {
			return { async resolveModelInfo() { return { inputModalities: ['text', 'image'] }; } };
		}
		return undefined;
	}
};

const config = new Config({});
apply(ctx, config);
console.log(`config: ${JSON.stringify(config)}`);
console.log(`tools: ${[...registered.keys()].join(', ')}`);

for (const [toolName, tool] of registered) {
	console.log(`\n--- ${toolName} ---`);
	console.log(`description: ${tool.description.length} chars`);
	console.log(`parameters: ${JSON.stringify(Object.keys(tool.parameters.properties ?? {}))}`);
	console.log(`required: ${JSON.stringify(tool.parameters.required ?? [])}`);
	console.log(`output schema root: ${tool.output.schema.type}${tool.output.schema.additionalProperties === false ? ' (closed)' : ''}`);
	if (typeof tool.output.render !== 'function') throw new Error(`${toolName} has no render`);
}

/**
 * Validate a candidate value against a compiled raw JSON Schema (the subset the
 * harness emits: type/required/additionalProperties/items/enum/properties).
 * @param schema - compiled schema node.
 * @param value - candidate value.
 * @param path - dotted path used in violations.
 * @returns the list of violations; empty means valid.
 */
function validate(schema, value, path) {
	const violations = [];
	if (schema === undefined || schema === null) return violations;
	// An explicitly undefined field is absent as far as JSON serialization and
	// the harness's validator are concerned, so it constrains nothing.
	if (value === undefined) return violations;
	const type = schema.type;
	if (type !== undefined) {
		const actual = value === null ? 'null' : Array.isArray(value) ? 'array' : typeof value;
		const ok = type === 'integer'
			? Number.isInteger(value)
			: type === 'number' ? typeof value === 'number'
				: type === 'array' ? Array.isArray(value)
					: type === 'object' ? (typeof value === 'object' && value !== null && !Array.isArray(value))
						: actual === type;
		if (!ok) {
			violations.push(`${path} should be ${type} but is ${actual}`);
			return violations;
		}
	}
	if (schema.enum !== undefined && !schema.enum.includes(value)) violations.push(`${path} is not one of ${JSON.stringify(schema.enum)}`);
	if (Array.isArray(value) && schema.items !== undefined) {
		value.forEach((entry, index) => violations.push(...validate(schema.items, entry, `${path}[${index}]`)));
	}
	if (typeof value === 'object' && value !== null && !Array.isArray(value)) {
		for (const key of schema.required ?? []) {
			if (!Object.hasOwn(value, key)) violations.push(`${path}.${key} is required but missing`);
		}
		for (const [key, entry] of Object.entries(value)) {
			const property = schema.properties?.[key];
			if (property === undefined) {
				if (schema.additionalProperties === false) violations.push(`${path}.${key} is not a declared property`);
				continue;
			}
			violations.push(...validate(property, entry, `${path}.${key}`));
		}
	}
	return violations;
}

/** Assert one value satisfies one tool's output schema. */
function assertOutput(toolName, value) {
	const tool = registered.get(toolName);
	const violations = validate(tool.output.schema, value, 'value');
	if (violations.length > 0) throw new Error(`${toolName} output rejected: ${violations.join('; ')}`);
}

// --- a frame captured with an attachment attached -----------------------------
const capture = {
	path: 'E:\\work\\.dsh-pilot\\screen-1.png',
	kind: 'primary',
	imageWidth: 2560,
	imageHeight: 1600,
	originX: 0,
	originY: 0,
	scale: 1,
	screens: [{ device: '\\\\.\\DISPLAY1', primary: true, bounds: '0,0,2560,1600' }],
	cursor: { x: 10, y: 20, screen: '\\\\.\\DISPLAY1' },
	foregroundWindow: { handle: '0x1', title: 'Notepad', class: 'Notepad', process: 'notepad', pid: 42, bounds: '0,0,800,600' },
	image: { attachmentId: 'sha256:stub', mediaType: 'image/png', bytes: 1234, width: 2560, height: 1600, name: 'screen-1.png' },
	capturedAt: '2026-09-21T22:00:00.0000000+08:00'
};

const screenView = registered.get('screen_view');
assertOutput('screen_view', capture);
const viewBlocks = screenView.output.render({}, capture);
console.log(`\nscreen_view render blocks: ${viewBlocks.map((block) => block.type).join(', ')}`);
console.log(viewBlocks[0].text);

// --- the shape desktop_control actually returns -------------------------------
// IMPORTANT: this mirrors what execute() copies out of the helper result. The
// helper's own `ok` key must NOT appear here: the runtime enforces
// additionalProperties:false on this object, and an undeclared key is rejected
// after the action has already been performed.
const controlResult = {
	action: 'move',
	cursor: { x: 100, y: 200 },
	foregroundTitle: 'Notepad',
	foregroundProcess: 'notepad',
	foregroundClass: 'Notepad',
	notes: ['a note'],
	actedAt: '2026-09-21T22:00:00.0000000+08:00',
	capturePath: capture.path,
	capture
};

const control = registered.get('desktop_control');
assertOutput('desktop_control', controlResult);
const controlBlocks = control.output.render({}, controlResult);
console.log(`\ndesktop_control render blocks: ${controlBlocks.map((block) => block.type).join(', ')}`);
console.log(controlBlocks[0].text);

// The `windows` variant of the same tool. These entries mirror what the sensor
// actually reports — _dsh-action.ps1 emits handle/title/class/process/pid/bounds/
// visible/minimized/foreground — because the schema is closed. Copy the SENSOR's
// shape here, never the schema's: the regression that shipped was `visible`,
// reported by the sensor, missing from the schema, and these samples were written
// from the schema, so the one field that mattered was the one field not covered.
assertOutput('desktop_control', {
	action: 'windows',
	cursor: { x: 1, y: 2 },
	foregroundTitle: 'Notepad',
	windows: [{ handle: '0x1', title: 'Notepad', class: 'Notepad', process: 'notepad', pid: 42, bounds: '0,0,800,600', visible: true, minimized: false, foreground: true }],
	windowCount: 1,
	notes: [],
	actedAt: '2026-09-21T22:00:00.0000000+08:00'
});

// A tray-hidden window reports visible:false alongside both flags, and an entry
// that omits the optional flags is still valid.
assertOutput('desktop_control', {
	action: 'windows',
	cursor: { x: 1, y: 2 },
	windows: [{ handle: '0x2', title: 'Hidden', class: 'X', process: 'x', pid: 7, bounds: '-32000,-32000,100,100', visible: false, minimized: true, foreground: false }],
	windowCount: 1,
	notes: [],
	actedAt: '2026-09-21T22:00:00.0000000+08:00'
});

// A window entry may only carry declared fields: anything else the sensor reports
// has to be dropped by windowInfoOf() before the result leaves execute().
const windowItemSchema = control.output.schema.properties.windows.items;
const undeclaredEntry = validate(windowItemSchema, { handle: '0x3', title: 'x', visible: true, bookkeeping: 1 }, 'entry');
if (undeclaredEntry.length === 0) throw new Error('a windows entry accepted an undeclared sensor key; the closed schema is not closed');
console.log(`\nwindows entries reject undeclared sensor keys: ${undeclaredEntry.join('; ')}`);

// The sensor's own `foregroundWindow` entry must project onto the same schema.
assertOutput('screen_view', {
	...capture,
	foregroundWindow: { handle: '0x1', title: 'Notepad', class: 'Notepad', process: 'notepad', pid: 42, bounds: '0,0,800,600', minimized: false, foreground: true }
});

// A result without an image must still render (the no-attachment-store case).
const bareCapture = { ...capture, image: undefined, imageError: 'no store' };
const bare = screenView.output.render({}, bareCapture);
assertOutput('screen_view', bareCapture);
console.log(`\nbare render blocks: ${bare.map((block) => block.type).join(', ')}`);

// --- the regression that shipped: undeclared helper keys ----------------------
const leaky = { ...controlResult, ok: true };
const leakViolations = validate(control.output.schema, leaky, 'value');
if (leakViolations.length === 0) throw new Error('validator failed to catch an undeclared key; the guard is useless');
console.log(`\nvalidator catches undeclared keys: ${leakViolations.join('; ')}`);

console.log('\nSMOKE OK');
