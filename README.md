# dsh-pilot

Real-time desktop vision and control for the DeepSeek Harness Desktop: the model
can **look at the actual screen** and then **operate it**.

- `screen_view` — captures the live desktop and returns the PNG as a real image
  block, so the model reads the screen instead of guessing about it.
- `desktop_control` — moves the pointer, clicks, drags, scrolls, types, sends
  keys, focuses windows, and lists windows, then optionally captures again in
  the same tool result so the effect is visible immediately.

Two halves, one coordinate space: the sensor (`desktop-probe.ps1`) reports the
geometry, the effector (`desktop-action.ps1`) consumes the same physical pixels.
Both PowerShell children make themselves **per-monitor DPI aware** before doing
anything, which is what makes that true — a DPI-unaware process is lied to by
Windows and sees this 2560×1600 panel as 1707×1067, so every click computed from
such a screenshot lands in the wrong place.

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

`type` delivers the text as **one paste** (clipboard set, `Ctrl+V`, clipboard
restored), so applications see a single insertion rather than per-character
typing. `windows` returns every visible titled top-level window with its bounds,
minimized state, and which one is foreground — useful before clicking anything.

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
the desktop checkout and exercises both schemas and both renderers without a
harness restart:

```powershell
# the package resolves @deepseek-ai/* from the desktop app's node_modules
New-Item -ItemType Junction -Path node_modules\@deepseek-ai `
  -Target "D:\AGAENT\DSH Desktop\resources\app\node_modules\@deepseek-ai"
node tools/smoke.mjs "D:\AGAENT\DSH Desktop\resources\app"
```

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

