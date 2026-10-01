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
- **Three modes** — record, live stream, or instant replay — switchable from the panel
- **Live streaming** to TikTok / Twitch / YouTube / any RTMP endpoint, with per-platform encode presets (H.264 + AAC, CBR, suggested resolution/fps/bitrate) and an optional local backup copy
  - The stream key is held in memory for the session and passed to gsr via the `GSR_AUTH` environment variable, so it never appears in `/proc/<pid>/cmdline` or in `shell.json` unless you explicitly enable "remember key"
- **Volume control** for desktop audio and microphone — the levels are read before recording, the requested levels are applied via `wpctl`, and your previous levels are restored when recording stops
- **Audio device selectors** for desktop and mic (fed by `gpu-screen-recorder --list-audio-devices`, drive gsr's `-a` capture sources directly)
- **Audio codec (AAC/Opus) and bitrate** control (0–512 kbps, auto when 0)
- **Noise gate** via FFmpeg's `afftdn`+`agate` filter
- **Webcam overlay** for recordings and streams: enable/disable, device, size — composited into the capture (`-w target|/dev/video0`, bottom-right)
- **Portal session restore** (`-restore-portal-session`) persists your Wayland portal session across recordings
- **Instant replay** (third mode): rolling buffer of the last N seconds stored in RAM or on disk (CBR for predictable RAM) — save a clip from the panel button or the **S** key, then the buffer restarts
- **Low-power capture** (AMD): reduces GPU clocks and switches to content-aware frame mode
- **Auto-optimized encoder settings** based on detected GPU vendor + available codecs:
  - NVIDIA — HEVC (H.265) → H.264 fallback, VBR, very-high, performance tune
  - AMD / Intel — AV1 → HEVC → H.264, VBR, very-high/high, performance tune
  - CPU fallback — H.264, QP, medium
- Hardware probing via `gpu-screen-recorder --info` (primary) with DRM/nvidia-smi fallbacks
- Region picking (`omarchy-capture-region`), monitor selection, or window/portal capture
- Pause / resume over the GSR unix-socket IPC (`scripts/gsr-ipc.py`)
- Runtime settings persisted inline to `~/.config/omarchy/shell.json` (entry `pix.recast`)
- Compatible with stock indicators via `/tmp/omarchy-screenrecord-filename`
- Save/failure notifications via `omarchy-notification-send`

## Requirements

- Omarchy 4.x (Quickshell 0.3+)
- `gpu-screen-recorder` (≥ 6.0) with a matching GPU driver
- `omarchy-capture-region`, `omarchy-notification-send` (bundled with Omarchy)
- `python3` for the IPC client

## Install

```
omarchy plugin add https://github.com/pxllbt/better-recast.git --enable
omarchy plugin enable pix.recast
omarchy-shell shell toggle pix.recast   # open the control panel
omarchy-shell bar layout right add pix.recast   # add the bar indicator
```

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

## Files

| Path | Purpose |
| --- | --- |
| `manifest.json` | Plugin manifest (schema v1, service + bar-widget) |
| `Service.qml`   | Backend: hardware probe, recording state machine, GSR process/IPC |
| `BarWidget.qml` | Bar indicator: state + elapsed, click to record/stop, right-click panel |
| `Panel.qml`     | Floating control panel: target, settings, hardware, diagnostics |
| `Config.js`     | Normed config model + per-vendor encoder profile rules |
| `GpuProbe.js`   | `gpu-screen-recorder --info` parser + fallbacks |
| `scripts/gsr-ipc.py` | Unix-socket JSON IPC client for pause/resume/stop |

## License

MIT — see [LICENSE](LICENSE).
