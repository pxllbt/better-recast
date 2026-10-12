# Better Recast

![Omarchy](https://img.shields.io/badge/Omarchy-4.x-1e66f5?style=flat-square)
![Quickshell](https://img.shields.io/badge/Quickshell-1e66f5?style=flat-square)
![License](https://img.shields.io/badge/License-MIT-1e66f5?style=flat-square)

GPU-accelerated screen recording for the Omarchy shell, backed by
[gpu-screen-recorder](https://git.dec05eba.com/gpu-screen-recorder/about/) with
automatic hardware and encoder detection.

![Better Recast preview](assets/previews/preview.gif)

## Features

- One-click record/stop from the bar widget (left click toggle, right click panel)
- **A distinct icon per state in the bar** — the resting glyph is idle only:
  record-circle while recording, pause while paused, broadcast while live,
  history while the replay buffer runs, so the recorder's state reads at a glance
- **Three modes** — record, live stream, or instant replay — switchable from the panel
- **Recording OSD** — a small pill (dot + REC/LIVE/REPLAY/PAUSED + elapsed time)
  shown only while recording, position configurable (top-right / top-center / bottom-right)
- **Live streaming** to TikTok / Twitch / YouTube / any RTMP endpoint, with per-platform encode presets (H.264 + AAC, CBR, suggested resolution/fps/bitrate) and an optional local backup copy
  - The stream key is held in memory for the session and passed to gsr via the `GSR_AUTH` environment variable, so it never appears in `/proc/<pid>/cmdline` or in `shell.json` unless you explicitly enable "remember key"
- **Setting presets** — name the current setup and re-apply it in one click; stream
  credentials are never part of a preset
- **Saved regions** — store named geometries (WxH+X+Y) and capture them without
  re-picking
- **Application audio** — capturable applications (from
  `gpu-screen-recorder --list-application-audio`) appear in the desktop and mic
  selectors, so you can capture just one app's audio (`app:<name>`)
- **Volume control** for desktop audio and microphone — the levels are read before recording, the requested levels are applied via `wpctl`, and your previous levels are restored when recording stops
- **Audio device selectors** for desktop and mic (fed by `gpu-screen-recorder --list-audio-devices`, drive gsr's `-a` capture sources directly)
- **Audio codec (AAC/Opus) and bitrate** control (0–512 kbps, auto when 0)
- **Noise gate** via FFmpeg's `afftdn`+`agate` filter
- **Disk-space guard** — recording refuses to start below the configured free-space
  floor, instead of failing mid-clip when the disk fills
- **Filename templates and date folders** — name recordings with
  `%Y %m %d %H %M %S` tokens and optionally organize them into `YYYY-MM-DD/`
- **Trim the last clip** — cut start/end with ffmpeg (fast stream copy, or
  frame-accurate re-encode), saved beside the original as `<name>.trim.<ext>`
- **Recent recordings** — the newest files in the output folder with open and
  copy-path actions
- **Webcam overlay** for recordings and streams: enable/disable, device, size — composited into the capture (`-w target|/dev/video0`, bottom-right)
- **Portal session restore** (`-restore-portal-session`) persists your Wayland portal session across recordings
- **Instant replay** (third mode): rolling buffer of the last N seconds stored in RAM or on disk (CBR for predictable RAM) — save a clip from the panel button or the **S** key, then the buffer restarts
- **Low-power capture** (AMD): reduces GPU clocks and switches to content-aware frame mode
- **Pre-record countdown**: a configurable 3-2-1 overlay (with tick sound) delays
  recording/streaming start so you can ready the scene; set to `0` to disable or
  0–10 s under Settings
- **Auto-optimized encoder settings** based on detected GPU vendor + available codecs:
  - NVIDIA — HEVC (H.265) → H.264 fallback, VBR, very-high, performance tune
  - AMD / Intel — AV1 → HEVC → H.264, VBR, very-high/high, performance tune
  - CPU fallback — H.264, QP, medium
- Hardware probing via `gpu-screen-recorder --info` (primary) with DRM/nvidia-smi fallbacks
- Region picking (`omarchy-capture-region`), monitor selection, or window/portal capture
- Pause / resume over the GSR unix-socket IPC (`scripts/gsr-ipc.py`)
- Runtime settings persisted inline to `~/.config/omarchy/shell.json` (entry `pix.recast`)
- Presets and saved regions persist in `~/.local/state/pix-recast/presets.json`,
  so `omarchy plugin update` never resets them
- Compatible with stock indicators via `/tmp/omarchy-screenrecord-filename`
- Save/failure notifications via `omarchy-notification-send`, with a click action
  that opens the saved clip

## Settings reference

All settings live in `shell.json` under the `pix.recast` bar-layout entry and are
editable from the panel.

| Setting | Default | What it does |
| --- | --- | --- |
| `minFreeDiskMb` | `2000` | Free-space floor below which recording refuses to start |
| `fileNameTemplate` | `screenrecording-%Y%m%d_%H%M%S` | Recording file names; needs a time token or it falls back to the default |
| `organizeByDate` | `false` | Write recordings into `YYYY-MM-DD/` subfolders |
| `osdEnabled` | `true` | Show the floating recording indicator |
| `osdPosition` | `top-right` | OSD corner: `top-right` \| `top-center` \| `bottom-right` |

## Hotkeys

Everything the recorder does is reachable over the `px-recast` IPC target, so
Hyprland keybinds can drive it without opening the panel. Suggested defaults:

```conf
bind = SUPER+ALT, R, exec, ~/.local/bin/recast toggle            # start / stop
bind = SUPER+ALT, S, exec, ~/.local/bin/recast saveReplay        # save a replay clip
bind = SUPER+ALT, P, exec, ~/.local/bin/recast pause             # pause / resume
bind = SUPER+ALT, O, exec, ~/.local/bin/recast openClip          # open the last clip
```

Lua-style configs (Omarchy's `bindings.lua`):

```lua
o.bind("SUPER + ALT + R", "Toggle screen recording", "~/.local/bin/recast toggle")
o.bind("SUPER + ALT + S", "Save replay clip", "~/.local/bin/recast saveReplay")
o.bind("SUPER + ALT + P", "Pause or resume recording", "~/.local/bin/recast pause")
o.bind("SUPER + ALT + O", "Open the last clip", "~/.local/bin/recast openClip")
```

`~/.local/bin/recast` re-enables the plugin if it was disabled, then forwards to
`omarchy-shell px-recast <method>`. Available methods include `toggle`,
`record`, `stop`, `pause`, `resume`, `replay`, `saveReplay`, `openClip`,
`openFolder`, `status`, `refreshGpu`, `trim <start> <end> [precise]`,
`savePreset <name> <json>`, `applyPreset <name>`, `deletePreset <name>`,
`saveRegion <name>` and `applyRegion <name>`.

## Requirements

- Omarchy 4.x (Quickshell 0.3+)
- `gpu-screen-recorder` (≥ 6.0) with a matching GPU driver
- `omarchy-capture-region`, `omarchy-notification-send` (bundled with Omarchy)
- `python3` for the IPC client

### If `gpu-screen-recorder` is missing

The panel checks for the binary at startup and refuses to record when it is
absent, reporting the install command instead of failing:

```
gpu-screen-recorder isn't installed — install it with: pacman -S gpu-screen-recorder
```

Install it and press record again — the check re-runs on the press, so there is
no need to restart the shell.

## Install

```
omarchy plugin add https://github.com/pxllbt/better-recast.git --enable
omarchy plugin enable pix.recast
omarchy-shell shell toggle pix.recast   # open the control panel
omarchy-shell bar layout right add pix.recast   # add the bar indicator
```

### Under Better Bar

Better Bar hosts plugin widgets itself rather than summoning them into the
Omarchy bar window, so both the strip entry and the panel work there unchanged:

- **Left-click** the strip entry to open the bar widget, **right-click** for the
  settings panel.
- Settings changes go through the service IPC, so a mode switch takes effect on
  the click instead of waiting for the next poll.
- The panel opens as a popup anchored under the bar, and closing it — by Escape,
  by clicking away, or by closing the bar — closes both.

## Updating

The plugin does **not** check for or apply updates on its own — there is no
in-app updater, and nothing runs in the background. Update deliberately:

```
omarchy plugin update pix.recast --yes
```

Note this is a hard reset to `origin/main`: any local edits to the plugin files
are discarded. Fork and re-apply, or keep your changes in a commit you re-apply
afterwards.

## Development

```
omarchy plugin validate .   # manifest + entry point check
bash tests/smoke.sh         # headless QML load smoke test
```

`tests/smoke.sh` runs the node suites against the sources: `setConfig()` and
`_computeCfg()` from `Panel.qml` (mode tabs must reach the service IPC and
update the panel immediately), `countdown.test.js` (pre-roll and gsr version
probe), `state-read.test.js` (event-driven state reads), `filename.test.js`
(templates), `guard.test.js` (disk-space decision), `trim.test.js` (time specs
and ffmpeg argv), `recent.test.js` (recent list), `osd.test.js` (OSD wiring),
`bar-glyph.test.js` (per-state bar glyphs), `pause-state.test.js` (visible
pause), `presets.test.js` (preset merge + credential stripping),
`config-read.test.js` (fresh config reads), `appaudio.test.js` (application
audio parsing) and `readme.test.js` (docs stay in sync).

## Files

| Path | Purpose |
| --- | --- |
| `manifest.json` | Plugin manifest (schema v1, service + bar-widget + overlay) |
| `Service.qml`   | Backend: hardware probe, recording state machine, GSR process/IPC |
| `BarWidget.qml` | Bar indicator: state glyph + elapsed, click to record/stop, right-click panel |
| `Panel.qml`     | Floating control panel: target, settings, hardware, diagnostics |
| `Overlay.qml`   | Recording OSD (overlay entry point), reads the live service state |
| `TrimTool.qml`  | Post-recording trim controls mounted by the panel |
| `RecentRecordings.qml` | Recent-recordings list mounted by the panel |
| `PresetsSection.qml` | Setting presets and saved regions mounted by the panel |
| `Config.js`     | Normed config model, templates, trim args, preset merge rules |
| `GpuProbe.js`   | `gpu-screen-recorder --info` / audio / app-audio / webcam parsers |
| `scripts/gsr-ipc.py` | Unix-socket JSON IPC client for pause/resume/stop |

## License

MIT — see [LICENSE](LICENSE).
