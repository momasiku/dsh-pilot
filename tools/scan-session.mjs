// Decode a DSH session log by walking its zstd frames explicitly.
//
// The harness appends independent zstd frames as a session grows, and the last
// frame can be torn mid-write, which makes whole-file decompression fail. This
// finds each frame by its magic, expands the largest prefix that decodes
// cleanly, and advances — so a torn tail only costs the final frame.
//
// Usage: node tools/scan-session.mjs <session.v3.jsonl.zstd> [out.jsonl]

import { readFileSync, writeFileSync } from 'node:fs';
import { constants, zstdDecompressSync } from 'node:zlib';

const source = process.argv[2];
const outPath = process.argv[3];
if (source === undefined) {
	console.error('usage: node tools/scan-session.mjs <session.jsonl.zstd> [out.jsonl]');
	process.exit(2);
}

const bytes = readFileSync(source);
const parts = [];
let cursor = 0;
let frames = 0;
let torn = 0;

while (cursor < bytes.byteLength - 3) {
	// Find the next frame magic.
	let start = -1;
	for (let index = cursor; index < bytes.byteLength - 3; index += 1) {
		if (bytes[index] === 0x28 && bytes[index + 1] === 0xb5 && bytes[index + 2] === 0x2f && bytes[index + 3] === 0xfd) {
			start = index;
			break;
		}
	}
	if (start === -1) break;

	// Grow the candidate window until the frame decodes, then keep going.
	let best;
	for (let end = bytes.byteLength; end > start + 8; end -= 1) {
		if (bytes[end - 1] === 0x28 && bytes[end] === 0xb5) break;
		try {
			const decoded = zstdDecompressSync(bytes.subarray(start, end), { finishFlush: constants.ZSTD_e_flush });
			best = { end, decoded };
			break;
		} catch {
			// Try a shorter window.
		}
	}
	if (best === undefined) {
		torn += 1;
		break;
	}
	parts.push(Buffer.from(best.decoded).toString('utf8'));
	frames += 1;
	cursor = best.end;
}

const text = parts.join('');
console.log(`frames expanded: ${frames} (unreadable tail: ${torn}), ${bytes.byteLength} bytes -> ${text.length} chars`);
if (outPath !== undefined) {
	writeFileSync(outPath, text, 'utf8');
	console.log(`wrote ${outPath}`);
}

const lines = text.split(/\r?\n/u).filter((line) => line.trim().length > 0);
console.log(`events: ${lines.length}\n`);

const kinds = new Map();
for (const line of lines) {
	let row;
	try {
		row = JSON.parse(line);
	} catch {
		continue;
	}
	const key = row.type ?? row.kind ?? row.event ?? 'unknown';
	kinds.set(key, (kinds.get(key) ?? 0) + 1);
}
console.log('event kinds:');
for (const [key, count] of [...kinds].sort((left, right) => right[1] - left[1])) console.log(`  ${String(count).padStart(5)}  ${key}`);

console.log('\ninterrupt-shaped lines:');
let hits = 0;
for (const line of lines) {
	if (!/interrupt|abort|cancel|halt/i.test(line)) continue;
	hits += 1;
	console.log(`  ${line.length > 320 ? `${line.slice(0, 320)}...` : line}`);
}
if (hits === 0) console.log('  (none)');
console.log(`\ntotal: ${hits}`);
