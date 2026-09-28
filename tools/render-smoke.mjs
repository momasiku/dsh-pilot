// Render-level smoke for the coordinate reporting.
//
// The attachment store may deliver a smaller frame than the capture, and a model
// that reads a coordinate off a shrunk image and clicks it unchanged lands in the
// wrong place. These checks pin down what the model is told in each case:
//
//   * delivered == capture  -> the frame is 1:1 and the readings are screen pixels
//   * delivered <  capture  -> the envelope reports the delivered size, the ratio,
//                              and the multiplier to apply to every reading
//   * the rulers flag is announced when the frame carries them
//
// Pure rendering: no desktop, no PowerShell, no sandbox exception needed.
//
// Usage: node tools/render-smoke.mjs "D:\\AGAENT\\DSH Desktop\\resources\\app"
const appRoot = process.argv[2];
if (appRoot === undefined) {
	console.error('usage: node tools/render-smoke.mjs <app-root>');
	process.exit(2);
}

const appBase = `file:///${appRoot.replaceAll('\\', '/')}/`;
const { validateJsonSchemaValue } = await import(new URL('node_modules/@deepseek-ai/dsh-tools/lib/index.js', appBase).href);
const { Config, apply } = await import(new URL('../lib/index.js', import.meta.url).href);

let failures = 0;
function check(name, ok, detail) {
	console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${detail === undefined ? '' : ` — ${detail}`}`);
	if (!ok) failures += 1;
}

const registered = new Map();
const ctx = {
	tools: { register(tool) { registered.set(tool.name, tool); } },
	effect() {},
	get(service) {
		if (service === 'attachments') {
			return {
				imageLimits: { maxImageBytes: 64 * 1024 * 1024, maxMessageImageBytes: 64 * 1024 * 1024 },
				async saveImage(input) { return { attachmentId: 'sha256:stub', mediaType: input.mediaType, bytes: input.data.byteLength, width: 10, height: 10, name: input.name }; }
			};
		}
		if (service === 'llm') return { async resolveModelInfo() { return { inputModalities: ['text', 'image'] }; } };
		return undefined;
	}
};
apply(ctx, new Config({}));
// The worker is never started in a render test.
const screenView = registered.get('screen_view');
const sequence = registered.get('desktop_sequence');

function frameValue({ delivered, captured, rulers = true, image = true }) {
	return {
		path: 'C:/tmp/frame.png',
		kind: 'window',
		imageWidth: captured.width,
		imageHeight: captured.height,
		originX: 935,
		originY: 575,
		scale: 1,
		screens: [{ device: '\\\\.\\DISPLAY1', primary: true, bounds: '0,0,2560,1600' }],
		cursor: { x: 1491, y: 1064 },
		foregroundWindow: { handle: '0x1', title: 'Demo', process: 'demo', class: 'Demo', bounds: '935,575,690,450' },
		rulers,
		...(image ? { image: { attachmentId: 'sha256:stub', mediaType: 'image/png', bytes: 7002, width: delivered.width, height: delivered.height } } : {})
	};
}

// ── delivered == capture: the contract may promise 1:1 ──────────────────────
{
	const value = frameValue({ delivered: { width: 2261, height: 1000 }, captured: { width: 2261, height: 1000 } });
	const text = screenView.output.render({}, value)[0].text;
	check('1:1 frame reports the plain delivered size', text.includes('<image_size>2261x1000</image_size>'), text.split('\n')[2]);
	check('1:1 frame says nothing about scaling', !text.includes('<delivered_scale>'));
	check('1:1 frame promises coordinates can be used as-is', text.includes('call desktop_control with exactly x and y'));
	check('1:1 frame announces its rulers', text.includes('<rulers>'));
	const violations = validateJsonSchemaValue(screenView.output.schema, value);
	check('1:1 frame matches the closed output schema', violations.length === 0, violations.slice(0, 2).join('; '));
}

// ── delivered < capture: the readings must be scaled ────────────────────────
{
	const value = frameValue({ delivered: { width: 1974, height: 873 }, captured: { width: 2261, height: 1000 } });
	const text = screenView.output.render({}, value)[0].text;
	check('shrunk frame reports both sizes', text.includes('<image_size delivered="1974x873" captured="2261x1000">1974x873</image_size>'), text.split('\n')[2]);
	check('shrunk frame states the ratio', /delivered 1974x873 = 0\.873x capture/.test(text), (text.match(/<delivered_scale>.*<\/delivered_scale>/) ?? ['none'])[0]);
	check('shrunk frame gives the multiplier', text.includes('multiply image readings by 1.1454'), text.includes('1.1454') ? 'present' : 'missing');
	check('shrunk frame no longer promises 1:1', !text.includes('call desktop_control with exactly x and y'));
	const violations = validateJsonSchemaValue(screenView.output.schema, value);
	check('shrunk frame matches the closed output schema', violations.length === 0, violations.slice(0, 2).join('; '));
}

// ── the same rule has to hold for the other two tools ──────────────────────
{
	const capture = frameValue({ delivered: { width: 1974, height: 873 }, captured: { width: 2261, height: 1000 } });
	const control = screenView.output.render ? undefined : undefined;
	const controlText = registered.get('desktop_control').output.render({}, {
		action: 'click',
		cursor: { x: 100, y: 200 },
		foregroundTitle: 'Demo',
		foregroundProcess: 'demo',
		capture,
		capturePath: capture.path
	})[0].text;
	check('desktop_control repeats the multiplier for its frame', controlText.includes('1.1454') && !controlText.includes('exactly x and y'), controlText.split('\n').pop());

	const sequenceText = sequence.output.render({}, {
		risk: 'low',
		confirmed: false,
		stepCount: 1,
		executed: 1,
		failed: 0,
		steps: [{ index: 1, action: 'click', ok: true, ms: 12 }],
		capture,
		capturePath: capture.path
	})[0].text;
	check('desktop_sequence repeats the multiplier for its frame', sequenceText.includes('1.1454') && !sequenceText.includes('exactly x and y'), sequenceText.split('\n').pop());
}

// ── a frame with rulers turned off, and one that is not attached at all ────
{
	const withoutRulers = frameValue({ delivered: { width: 690, height: 330 }, captured: { width: 690, height: 330 }, rulers: false });
	const text = screenView.output.render({}, withoutRulers)[0].text;
	check('rulers are only announced when they are on', !text.includes('<rulers>'));

	const unattached = frameValue({ delivered: { width: 690, height: 330 }, captured: { width: 690, height: 330 }, image: false });
	unattached.imageSkipped = 'the current model route does not declare image input';
	const text2 = screenView.output.render({}, unattached)[0].text;
	check('an unattached frame reports the capture size and no contract', text2.includes('captured="2560x1600"') === false && text2.includes('delivered="none"') && !text2.includes('desktop_control with exactly'), text2.split('\n')[2]);
}

console.log(`\nrender-smoke: ${failures === 0 ? 'OK' : `${failures} check(s) failed`}`);
process.exit(failures === 0 ? 0 : 1);
