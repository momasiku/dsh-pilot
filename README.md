# dsh-pilot

Real-time desktop vision and control for the DeepSeek Harness Desktop: the model
can **look at the actual screen** and then **operate it**.

- `screen_view` — captures the live desktop and returns the PNG as a real image
  block, so the model reads the screen instead of guessing about it.
- `desktop_control` — moves the pointer, clicks, drags, scrolls, types, sends
  keys, focuses windows, and lists windows, then optionally captures again in
  the same tool result so the effect is visible immediately.
- `desktop_sequence` — runs a whole batch of those actions in **one** call and
  looks once at the end, which is where the speed comes from: the cost of desktop
  work is the number of model ↔ computer round trips, not the click itself.

Two halves, one coordinate space: the sensor (`desktop-probe.ps1`) reports the
geometry, the effector (`desktop-action.ps1`) consumes the same physical pixels.
Both PowerShell children make themselves **per-monitor DPI aware** before doing
anything, which is what makes that true — a DPI-unaware process is lied to by
Windows and sees this 2560×1600 panel as 1707×1067, so every click computed from
such a screenshot lands in the wrong place.

## Why a batch beats a call per action

A five-step task — focus the window, click a field, type, press Enter, glance at
the result — has two very different shapes:

| | one call per action | one `desktop_sequence` call |
| --- | --- | --- |
| model round trips | 5 | **1** |
| screenshots shipped | 4–5 | **1** |
| image tokens | 4–5 frames | **1 frame** |
| first failure | discovered a round trip later | reported in the same result |

The batch is also where the safety rails live, because a batch is the moment an
agent could do real damage in one go:

- **Risk is declared, then enforced.** Low risk (the default) batches freely. A
  batch declared `medium`/`high`, or one carrying a step marked `risk: "high"`,
  is refused *before anything touches the desktop* unless the caller passes
  `confirm: true` — which it does only after the user agreed.
- **`dryRun: true`** validates the batch and lists the plan without executing.
- **Stop on the first failure** (default): a refused `focus` can never be
  followed by typing into whatever window happens to be in front.
- **Bounded**: `maxSequenceSteps` (default 24) caps one batch.

### What the model is told about coordinates

A frame can come back smaller than it was captured: the attachment store re-encodes
within its own byte limits. A model that reads a coordinate off a shrunk image and
clicks it unchanged lands in the wrong place, so the envelope always states the size
it is actually delivering and, when that differs, the ratio and the multiplier:

```text
<image_size delivered="1974x873" captured="2261x1000">1974x873</image_size>
<delivered_scale>delivered 1974x873 = 0.873x capture; multiply image readings by 1.1454 to get screen pixels</delivered_scale>
```

The coordinate contract that follows every frame is conditional for the same reason:
it promises "one image pixel is one screen pixel, use x and y as they are" only when
the delivered frame is the capture, and otherwise says which multiplier to apply.

Frames also carry **coordinate rulers** (on by default; `rulers: false` turns them
off): ticks every 200 px along the top and left edge, each labelled with the screen
coordinate it sits at, so a position can be read straight off the image instead of
counting pixels — and the labels stay meaningful under the multiplier above.
### One warm process instead of a process per action

Starting PowerShell and compiling the Win32 bridge costs about a second, and that
used to be paid for every single action and every frame. The plugin now keeps one
worker process alive (`lib/scripts/desktop-worker.ps1`): the shared code lives in
`_dsh-win32.ps1`, `_dsh-action.ps1` and `_dsh-capture.ps1`, the one-shot scripts
(`desktop-action.ps1`, `desktop-probe.ps1`) stay as the fallback, and the worker
answers both kinds of request over a single stdin/stdout protocol.

Measured on this machine (2560x1600, 150% scaling, the harness UI animating):

| request | one-shot script | warm worker |
| --- | --- | --- |
| action (`move`, `click`, `type`, ...) | ~0.9-2.0 s | **6-12 ms** |
| capture (primary monitor) | ~1.2-2.3 s | **0.5 s** |

The worker is started in the background on the first tool call, so the ~1 s it
needs overlaps the first capture instead of delaying the first action. If it cannot
be started, or dies, requests fall back to the one-shot script - with one
exception: an action whose fate is unknown (the worker died after the request was
delivered) is reported as a failure instead of being retried silently, because it
may already have taken effect. `useWorker: false` disables the warm path entirely.
### Frames that did not change cost nothing

Every capture returns a `frameHash`. When a frame is byte-identical to the
previous frame of the same session, the image is **not attached again** (and not
stored again): the result reports `unchanged: true` plus the explanation, and the
coordinates from the frame the model already has still apply. Pass
`forceImage: true` when you want to see it anyway. That is what keeps a
verification loop from re-sending the same picture over and over.


## Tools

### `screen_view`

| parameter | type | meaning |
| --- | --- | --- |
| `screen` | string | `primary` (default), `all` (whole virtual desktop), or a 0-based monitor index |
| `window` | string | case-insensitive substring of a window title or process name; frames that window |
| `region` | string | crop as `x,y,width,height` in physical screen pixels |
| `includeCursor` | boolean | draw a crosshair at the pointer (default `true`) |

The result carries the image plus a `<screen_capture>` envelope: image size,
physical origin, scale, every monitor's bounds, cursor position, and the
foreground window (title, process, class, bounds).

### `desktop_control`

| parameter | type | meaning |
| --- | --- | --- |
| `action` | string, required | `click`, `doubleClick`, `rightClick`, `middleClick`, `move`, `drag`, `scroll`, `type`, `key`, `focus`, `windows` |
| `x`, `y` | integer | target in physical screen pixels; required by the pointer actions and by scroll-at-a-point |
| `toX`, `toY` | integer | drag end point, or a nonzero value to make `scroll` horizontal |
| `text` | string | text to insert for `type` |
| `key` | string | a character, `enter`/`tab`/`esc`/`f5`, or a chord like `ctrl+s`, `alt+tab`, `win` |
| `amount` | integer | wheel notches for `scroll` (default 3, positive scrolls up) |
| `button` | string | `left` (default), `right`, `middle` |
| `title` | string | window title or process substring; required by `focus`, filters `windows` |
| `capture` | boolean | capture a fresh frame after acting (default `true`) |
| `settleMs` | integer | wait before that capture so the screen can repaint (default 750) |
| `forceImage` | boolean | attach the frame even when it repeats the previous frame of the session |

`type` delivers the text as **one paste** (clipboard set, `Ctrl+V`, clipboard
restored), so applications see a single insertion rather than per-character
typing. `windows` returns every visible titled top-level window with its bounds,
minimized state, and which one is foreground — useful before clicking anything.

### `desktop_sequence`

| parameter | type | meaning |
| --- | --- | --- |
| `steps` | array, required | ordered steps; each is one `desktop_control` action **without** its own screenshot, plus optional `settleMs`, `risk`, `riskNote`; action `wait` takes `ms` |
| `risk` | string | `low` (default) / `medium` / `high`, the risk you declare for the whole batch |
| `confirm` | boolean | required for a medium/high batch; without it the tool refuses before touching the desktop |
| `dryRun` | boolean | validate the batch and list the plan without executing anything |
| `capture` | string | `end` (default) captures one frame after the last step, `none` skips it |
| `target` | string | `window` (default: the window that was foreground during the batch), `screen` (primary monitor), `all` (whole virtual desktop) |
| `window` | string | frame this window instead (title/process substring), overriding `target` |
| `region` | string | crop the end frame as `x,y,width,height` in physical pixels |
| `forceImage` | boolean | attach the end frame even when it repeats the previous frame |
| `stopOnError` | boolean | stop at the first failing step (default `true`) |
| `settleMs` | integer | delay before the end capture so the screen can repaint |

Each step is reported back with its own action, duration in milliseconds, and
outcome, so one call still tells the model exactly where a batch went wrong.

## Coordinate contract

Image pixel `(0,0)` is the top-left of the frame, and one image pixel is one real
screen pixel. To act on a feature at image `(x,y)`, pass exactly `x` and `y`.
Never rescale for display scaling. If `screen: all` was used on a multi-monitor
desktop, add nothing either: the envelope's `physical_origin` is already applied,
so the numbers the model reads off the image are the numbers the effector wants.

`GetCursorPos`/`SetCursorPos` consume the same physical pixels, and the action
script reports the resulting cursor position, so the loop is self-checking.

## Safety and interruption

- The plugin runs with whatever permissions the DSH process has. It cannot drive
  windows owned by a higher-integrity (elevated) process — Windows blocks that;
  the tool reports the failure instead of pretending it worked.
- `focus` walks a window to its root owner before activating and falls back to
  `AttachThreadInput`, because taskbar buttons are not activatable directly.
- A drag releases the mouse button in a `finally` block, so an abort can never
  leave the left button latched down.
- **Interruption:** the parent writes a cancel token and kills the child when the
  tool execution is aborted (pressing Esc in DSH). The action loop polls that
  token between every step — during drags, during the settle wait, and before
  the capture — so an interrupted turn stops a gesture in flight instead of
  letting the remaining clicks play out.
- Captured frames land in `<session cwd>/.dsh-pilot/` and are pruned to
  `captureRetention` (default 30). Pruning never breaks an image the conversation
  already carries, because attachments are stored content-addressed.

## Configuration

```yaml
- insert:
    - id: pilot
      name: dsh-pilot
      config:
        captureRetention: 30   # frames kept under .dsh-pilot/
        timeoutMs: 20000       # per-call kill deadline for a helper
        settleMs: 750          # default delay before the automatic capture
        stepSettleMs: 120      # per-step delay inside a desktop_sequence
        maxSequenceSteps: 24   # hard cap on the steps of one batch
        alwaysSaveFile: true   # keep the PNG even when no image block is attached
```

## Installing

```powershell
dsh plugin --profile <name> add "file:E:\path\to\dsh-pilot"
```

A plain plugin declares no `dsh.bundle`, so `dsh plugin add` installs it as a
dependency without adding a profile layer; add the `insert` row above to the
profile's `cordis.patch.yml`. Restart the desktop app afterwards so the new row
is composed and the tools join the tool list.

Requirements: Windows, PowerShell 5.1 or 7, and a model route that declares
image input (`deepseek-flash` does).

## Developing

The smoke test loads the plugin against the real `@deepseek-ai/dsh-tools` from
the desktop checkout and exercises every schema and renderer without a harness
restart:

```powershell
# the package resolves @deepseek-ai/* from the desktop app's node_modules
New-Item -ItemType Junction -Path node_modules\@deepseek-ai `
  -Target "D:\AGAENT\DSH Desktop\resources\app\node_modules\@deepseek-ai"
node tools/smoke.mjs "D:\AGAENT\DSH Desktop\resources\app"
node tools/sequence-smoke.mjs "D:\AGAENT\DSH Desktop\resources\app"
```

`sequence-smoke.mjs` is the end-to-end one: it drives a real batch against a
throwaway window it creates itself (never one of your applications), and the
window writes back what it received — so "focus, then type, then Enter" is proven
to have happened in that order, not merely attempted. It also checks the risk
gate, `dryRun`, the frame deduplication, and that the result matches the closed
output schema. It needs a full-access shell: the plugin reads its helpers through
pipes, which a restricted sandbox denies with `EPERM`.

The helper scripts can be driven directly while debugging — they take a UTF-8
JSON params file and print one JSON result:

```powershell
'{"out":"E:\tmp\shot.png","screen":"primary"}' | Set-Content params.json -Encoding utf8
powershell -NoProfile -File lib\scripts\desktop-probe.ps1  -ParamsPath params.json
powershell -NoProfile -File lib\scripts\desktop-action.ps1 -ParamsPath params.json
```

Keep the `.ps1` files saved **with a UTF-8 BOM**: Windows PowerShell reads
BOM-less files as ANSI, which mangles non-ASCII window titles and paths.

### Reinstalling after an edit

`dsh plugin add file:...` installs a **copy**, and a repeat `add` of an unchanged
`file:` spec reports "Already up to date" without re-copying even when the files
on disk changed. After editing, copy the changed files into the installed
package yourself and restart the desktop app:

```powershell
$src = "E:\path\to\dsh-pilot"
$dst = "$env:USERPROFILE\.dsh\profiles\<profile>\node_modules\dsh-pilot"
Copy-Item "$src\lib\index.js" "$dst\lib\index.js" -Force
```

### Why the smoke test validates result shapes

A tool result carrying a key its closed output schema does not declare is
rejected by the runtime **after** `execute()` has already performed the side
effect — so the action happens yet the caller sees an error. A schema-only check
cannot see that failure mode, so `smoke.mjs` validates a realistic result object
against each tool's compiled output schema, and additionally asserts that the
validator itself catches the undeclared `ok`/`actedAt` keys that shipped once.

