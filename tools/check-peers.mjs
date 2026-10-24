// Fail when this package's declared dsh-* peer ranges stop matching the host
// generation that is actually installed.
//
// The host runs this plugin in-process, so the harness API is this plugin's
// runtime, and two different evaluators read the same declaration:
//
//   dsh's own gate   satisfies(version, range, { includePrerelease: true })
//   pnpm / npm       satisfies(version, range)            -- default rules
//
// They disagree on prerelease ranges, and a range can pass the gate while
// failing the installer. `>=0.1.5-rc.2 <0.3.0-0` matches 0.2.0-rc.2 under the
// gate but NOT under pnpm: node-semver lets a prerelease satisfy a range only
// when some comparator in that range carries a prerelease tag on the same
// major.minor.patch tuple, and that range has no comparator on the 0.2.0 tuple.
// Spelling the generation out as its own `||` branch satisfies both:
//
//   ">=0.1.5-rc.2 <0.2.0 || >=0.2.0-rc.1 <0.3.0-0"
//
// Usage: node tools/check-peers.mjs [app-root]
//   app-root defaults to the current directory and must be ABSOLUTE in CI:
//   the sibling smoke tests build a file:// URL from it.

import fs from 'node:fs'
import path from 'node:path'
import { createRequire } from 'node:module'

const appRoot = path.resolve(process.argv[2] ?? '.')
const manifest = JSON.parse(fs.readFileSync(new URL('../package.json', import.meta.url), 'utf8'))

let semver
try {
	semver = createRequire(path.join(appRoot, 'package.json'))('semver')
} catch {
	console.error(`semver is not resolvable from ${appRoot} — run: npm install --no-save semver`)
	process.exit(2)
}

const peers = Object.entries(manifest.peerDependencies ?? {}).filter(
	([name]) => name === '@deepseek-ai/dsh' || name.startsWith('@deepseek-ai/dsh-'),
)
if (peers.length === 0) {
	console.log(`${manifest.name}@${manifest.version} declares no dsh runtime peers — nothing to judge`)
	process.exit(0)
}

/**
 * Read a file out of an Electron asar archive.
 * Electron's patched fs treats any path ending in .asar as an archive and refuses
 * to hand back the bytes, so a failed read falls back to a copy with a neutral
 * extension. CI runs plain node and takes the first branch.
 */
function readAsar(asarPath, inner) {
	let buf
	try {
		buf = fs.readFileSync(asarPath)
	} catch {
		const tmp = path.join(os.tmpdir(), `dsh-asar-${process.pid}.bin`)
		fs.copyFileSync(asarPath, tmp)
		buf = fs.readFileSync(tmp)
		fs.rmSync(tmp, { force: true })
	}
	const headerSize = buf.readUInt32LE(4)
	const region = buf.subarray(8, 8 + headerSize)
	const start = region.indexOf('{"files"')
	if (start < 0) throw new Error(`${asarPath}: no asar header found`)
	// The header string is padded to a 4-byte boundary with NULs, and JSON.parse
	// rejects anything after the closing brace, so the padding has to go first.
	const header = JSON.parse(region.subarray(start).toString('utf8').replace(/[\u0000\s]+$/, ''))
	const base = 8 + headerSize
	let node = header
	for (const part of inner.split('/')) {
		node = node.files?.[part]
		if (!node) throw new Error(`${asarPath}: no ${inner} in the archive`)
	}
	return JSON.parse(buf.subarray(base + Number(node.offset), base + Number(node.offset) + Number(node.size)).toString('utf8'))
}

/** name -> version for the host packages the running app ships. */
function hostFromAsar(asarPath) {
	const runtime = readAsar(asarPath, 'dsh/desktop-runtime.json')
	const versions = new Map()
	for (const pkg of runtime.sharedPackages ?? []) versions.set(pkg.name, pkg.version)
	return { versions, release: runtime.release?.version }
}

const args = process.argv.slice(3)
const asarIndex = args.indexOf('--asar')
const wantAsar = asarIndex >= 0
let host = null
if (wantAsar) {
	const given = args[asarIndex + 1] && !args[asarIndex + 1].startsWith('--') ? args[asarIndex + 1] : null
	const candidates = [
		given,
		path.join(process.env.LOCALAPPDATA ?? '', 'Programs', 'DeepSeek Harness', 'resources', 'app.asar'),
	].filter(Boolean)
	const found = candidates.find((c) => fs.existsSync(c))
	if (!found) {
		console.error('--asar: no installed desktop app found; pass the path: node tools/check-peers.mjs . --asar <app.asar>')
		process.exit(2)
	}
	host = hostFromAsar(found)
	console.log(`host generation inside ${found}`)
	console.log(`     desktop release ${host.release}`)
} else {
	console.log(`host generation under ${appRoot}`)
}
let failed = 0
for (const [peer, range] of peers) {
	let version
	if (host) {
		// What the shipped app actually carries. A peer it does not bundle is judged
		// against the harness release it does carry: those move together.
		version = host.versions.get(peer) ?? host.versions.get('@deepseek-ai/dsh')
		if (!version) {
			console.log(`??   ${peer} is not in that asar — cannot judge "${range}"`)
			failed += 1
			continue
		}
	} else {
		const manifestPath = path.join(appRoot, 'node_modules', ...peer.split('/'), 'package.json')
		try {
			version = JSON.parse(fs.readFileSync(manifestPath, 'utf8')).version
		} catch {
			console.log(`??   ${peer} is not installed here — cannot judge "${range}"`)
			failed += 1
			continue
		}
	}
	const gate = semver.satisfies(version, range, { includePrerelease: true })
	const plain = semver.satisfies(version, range)
	if (gate && plain) {
		console.log(`ok   ${peer}@${version} matches "${range}"`)
	} else {
		failed += 1
		console.log(`FAIL ${peer}@${version} does not match "${range}"  (dsh gate=${gate ? 'pass' : 'fail'}, pnpm=${plain ? 'pass' : 'fail'})`)
	}
}

if (failed) {
	console.error(`\n${failed} peer check(s) failed. The host moved: either widen the range in package.json (add the new generation as its own || branch) or fix the plugin against the new API.`)
	process.exit(1)
}
console.log(host
	? '\nall dsh peer ranges match the generation this desktop app ships'
	: '\nall dsh peer ranges match the installed host generation')
