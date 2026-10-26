// pilot / tools/cursor-accuracy.mjs - does the pointer land where we said?
//
// Three numbers matter and they are not the same number:
//   requested  what the caller asked for
//   reported   what the helper says the cursor is after moving
//   actual     what the OS says, read by a separate process
//
// If reported and actual disagree the plugin is lying to the model. If actual and
// requested disagree the click lands somewhere else. Either one breaks 'it points
// where it says it points', so this walks a set of points and checks all three.
//
// Usage: node tools/cursor-accuracy.mjs <repo-root> [--points=8]

import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

const root = path.resolve(process.argv[2] ?? '.')
const countArg = process.argv.find((a) => a.startsWith('--points='))
const extra = countArg ? Number(countArg.split('=')[1]) : 8

const helper = path.join(root, 'lib', 'scripts', 'desktop-action.ps1')
if (!fs.existsSync(helper)) { console.error('no helper at ' + helper); process.exit(2) }

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'pilot-cursor-'))

const probeSrc = [
  'Add-Type -TypeDefinition @"',
  'using System;',
  'using System.Runtime.InteropServices;',
  'public class ProbePoint {',
  '  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }',
  '  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);',
  '}',
  '"@',
  '$p = [ProbePoint+POINT]::new()',
  'if ([ProbePoint]::GetCursorPos([ref] $p)) { Write-Output ("{0},{1}" -f $p.X, $p.Y) } else { Write-Output "fail" }',
].join('\r\n')
const probe = path.join(tmp, 'probe.ps1')
fs.writeFileSync(probe, probeSrc, 'utf8')

function actualCursor() {
  const out = spawnSync('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', probe], { encoding: 'utf8' })
  const text = (out.stdout ?? '').trim()
  const m = /^(-?\d+),(-?\d+)$/.exec(text)
  return m ? { x: Number(m[1]), y: Number(m[2]) } : null
}

function moveTo(x, y) {
  const params = path.join(tmp, 'p' + Math.random().toString(36).slice(2) + '.json')
  fs.writeFileSync(params, JSON.stringify({ action: 'move', x: x, y: y, settleMs: 0, capture: false }))
  const out = spawnSync('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', helper, '-ParamsPath', params], { encoding: 'utf8' })
  try { return JSON.parse((out.stdout ?? '').trim()) } catch { return { ok: false, error: 'unparseable: ' + (out.stdout ?? '').slice(0, 80) } }
}

const screenRead = spawnSync('powershell.exe', ['-NoProfile', '-Command',
  'Add-Type -AssemblyName System.Windows.Forms; $b=[System.Windows.Forms.Screen]::PrimaryScreen.Bounds; Write-Output ("{0},{1}" -f $b.Width,$b.Height)'],
  { encoding: 'utf8' })
const dims = /^(\d+),(\d+)$/.exec((screenRead.stdout ?? '').trim())
if (!dims) { console.error('could not read the primary screen size'); process.exit(2) }
const W = Number(dims[1])
const H = Number(dims[2])

const points = [
  { x: 0, y: 0, name: 'top-left corner' },
  { x: W - 1, y: 0, name: 'top-right corner' },
  { x: 0, y: H - 1, name: 'bottom-left corner' },
  { x: W - 1, y: H - 1, name: 'bottom-right corner' },
  { x: Math.floor(W / 2), y: Math.floor(H / 2), name: 'centre' },
]
for (let i = 0; i < extra; i++) {
  points.push({ x: 1 + Math.floor(Math.random() * (W - 2)), y: 1 + Math.floor(Math.random() * (H - 2)), name: 'random ' + (i + 1) })
}

console.log('screen ' + W + 'x' + H + ', ' + points.length + ' points')
console.log('  ' + 'point'.padEnd(18) + 'asked'.padEnd(14) + 'reported'.padEnd(14) + 'actual'.padEnd(14) + 'err')
let worstRequest = 0
let worstReport = 0
let failures = 0
for (const p of points) {
  const result = moveTo(p.x, p.y)
  const reported = result?.cursor ?? null
  const actual = actualCursor()
  const errRequest = actual ? Math.max(Math.abs(actual.x - p.x), Math.abs(actual.y - p.y)) : 9999
  const errReport = (actual && reported) ? Math.max(Math.abs(actual.x - reported.x), Math.abs(actual.y - reported.y)) : 9999
  worstRequest = Math.max(worstRequest, errRequest)
  worstReport = Math.max(worstReport, errReport)
  const bad = errRequest !== 0 || errReport !== 0
  if (bad) failures++
  console.log('  ' + p.name.padEnd(18) + (p.x + ',' + p.y).padEnd(14) +
    (reported ? reported.x + ',' + reported.y : '?').padEnd(14) +
    (actual ? actual.x + ',' + actual.y : '?').padEnd(14) +
    'ask ' + errRequest + ' / report ' + errReport + (bad ? '  <- FAIL' : ''))
}

fs.rmSync(tmp, { recursive: true, force: true })
console.log('')
console.log('worst |actual - asked|    = ' + worstRequest + ' px')
console.log('worst |actual - reported| = ' + worstReport + ' px')
if (failures > 0) { console.error(failures + ' of ' + points.length + ' points are off'); process.exit(1) }
console.log('cursor-accuracy: OK - every point landed where it was asked and where it was reported')