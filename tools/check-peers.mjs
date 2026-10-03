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

console.log(`host generation under ${appRoot}`)
let failed = 0
for (const [peer, range] of peers) {
	const manifestPath = path.join(appRoot, 'node_modules', ...peer.split('/'), 'package.json')
	let version
	try {
		version = JSON.parse(fs.readFileSync(manifestPath, 'utf8')).version
	} catch {
		console.log(`??   ${peer} is not installed here — cannot judge "${range}"`)
		failed += 1
		continue
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
console.log('\nall dsh peer ranges match the installed host generation')
