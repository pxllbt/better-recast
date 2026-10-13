<div align="center">

# Better Recast

**High-performance GPU-accelerated screen recording, live streaming, and instant replay for Omarchy & Wayland.**

[![CI](https://img.shields.io/github/actions/workflow/status/pxllbt/better-recast/ci.yml?branch=main&style=flat-square&label=CI)](https://github.com/pxllbt/better-recast/actions)
[![Omarchy](https://img.shields.io/badge/Omarchy-4.x-1e66f5?style=flat-square)](https://omarchy.org)
[![Quickshell](https://img.shields.io/badge/Quickshell-0.3%2B-1e66f5?style=flat-square)](https://quickshell.outfoxxed.me)
[![GPU Accelerated](https://img.shields.io/badge/GPU-NVENC%20%7C%20VAAPI%20%7C%20QSV-00c853?style=flat-square)](#-hardware-support--encoding-matrix)
[![Idle CPU](https://img.shields.io/badge/Idle%20CPU-0.0%25-brightgreen?style=flat-square)](#-performance--architecture)
[![License](https://img.shields.io/badge/License-MIT-blue?style=flat-square)](LICENSE)

<br/>

<img src="preview.png" alt="Better Recast" width="100%" />

<br/>

*Studio Quality · Hardware Accelerated · Near-Zero Overhead*

[Overview](#-overview) • [Features](#-features) • [Hardware Support](#-hardware-support--encoding-matrix) • [Installation](#-installation) • [Keybindings](#-keybindings--hotkeys) • [Configuration](#-settings-reference) • [Architecture](#-performance--architecture) • [Contributing](#-contributing)

</div>

---

## 🌟 Overview

**Better Recast** (`pix.recast`) is a studio-grade screen recording, RTMP streaming, and instant replay system built natively for [Omarchy](https://omarchy.org) and [Quickshell](https://quickshell.outfoxxed.me) on Wayland.

Powered by [gpu-screen-recorder](https://git.dec05eba.com/gpu-screen-recorder/about/), Better Recast captures desktop video directly from the GPU framebuffer without copying frames through system RAM or the CPU. It features automatic hardware and encoder detection, per-application audio isolation, an interactive floating control panel, live pre-roll countdowns, and instant dynamic island status integration with [Better Bar](https://github.com/pxllbt/better-bar).

---

## ✨ Features

### 🎬 Three Core Modes
- **Screen Recording**: Clean, stutter-free desktop capture to crash-safe MKV or MP4 containers with customizable bitrate, framerate (up to 240 FPS), resolution scaling, and color ranges.
- **Live Streaming**: Direct low-latency RTMP broadcasting to Twitch, YouTube, Kick, TikTok, or custom servers with automatic platform-specific encoding profiles (CBR, keyframe intervals, and audio bitrate).
- **Instant Replay**: Continuous circular replay buffer stored in RAM or on disk. Save the last 15s to 20 minutes of gameplay with a single tap of the **S** key or hotkey.

### 🎙️ Audio Routing & Application Isolation
- **Application Audio Capture**: Select specific running applications (via `gpu-screen-recorder --list-application-audio`) to isolate game or music audio (`app:<name>`) independently from desktop sounds.
- **Microphone & Desktop Mix**: Discrete volume sliders for microphone and desktop channels with automatic level restoration via `wpctl` when recording stops.
- **Noise Gate & Filtering**: Built-in noise gating and audio filtering powered by FFmpeg filters (`afftdn` + `agate`).
- **Codec Selection**: Uncompressed PCM, high-efficiency AAC, or low-latency Opus audio codecs.

### ⚡ Studio Controls & Safety
- **Dynamic Island Integration**: Native REC/PAUSED/STARTING chip in Better Bar with elapsed time and pre-roll countdown.
- **Recording OSD**: Floating on-screen display pill (recording indicator + timer + status) placed in your preferred screen corner (`top-right`, `top-center`, or `bottom-right`).
- **Pre-Roll Countdown**: Configurable 3, 5, or 10-second visual and audio pre-roll countdown to prepare your scene before capture begins.
- **Disk Space Safety Guard**: Configurable free-space threshold (`minFreeDiskMb`) preventing captures from corrupting or crashing when storage runs low.
- **Post-Recording Trim Tool**: Quick stream-copy cutting or frame-accurate re-encoding built right into the control panel.
- **Recent Recordings Carousel**: Fast access to recent clips with single-click folder open and path copy actions.
- **Presets & Saved Regions**: Save customized capture geometries (WxH+X+Y) and encoder presets stored in `~/.local/state/pix-recast/presets.json` across plugin updates.

---

## ⚡ Hardware Support & Encoding Matrix

Better Recast automatically detects installed GPUs via `gpu-screen-recorder --info` and picks optimal encode profiles:

| GPU Architecture | Primary Backend | Recommended Codecs | Encoder Features |
| :--- | :--- | :--- | :--- |
| **NVIDIA GeForce / RTX** | NVENC (NVFBC / CUDA) | `hevc` (H.265), `h264`, `av1` | Low latency, performance tune, NVENC SDK |
| **AMD Radeon (RX / RDNA)** | VAAPI | `av1`, `hevc` (H.265), `h264` | Native VAAPI hardware encode, low power mode |
| **Intel Arc / UHD / Iris** | QuickSync / VAAPI | `av1`, `hevc`, `h264` | Intel Media SDK / VAAPI hardware encode |
| **Software Fallback** | CPU (x264 / x265) | `h264_software` | Constant Rate Factor (CRF), multithreaded |

---

## 📦 Installation

### Prerequisites
Make sure `gpu-screen-recorder` and runtime dependencies are installed:

```bash
# Arch Linux
sudo pacman -S gpu-screen-recorder python ffmpeg
```

### Install with Omarchy

Install Better Recast directly using the Omarchy plugin manager:

```bash
omarchy plugin add https://github.com/pxllbt/better-recast.git --enable
omarchy plugin enable pix.recast
```

Add the indicator to your status bar:

```bash
omarchy-shell bar layout right add pix.recast
```

Open the control panel:

```bash
omarchy-shell shell toggle pix.recast
```

### Integration with Better Bar

If you use [Better Bar](https://github.com/pxllbt/better-bar), Better Recast integrates natively:
- **Left-Click**: Toggle recording (starts if idle, stops if live).
- **Right-Click**: Instantly toggle the settings control panel anchored right to the button.
- **Dynamic Island**: Displays live pre-roll countdown (`STARTING 3…`), recording counter (`REC 00:05`), and paused status with near-zero compositor overhead.

---

## ⌨️ Keybindings & Hotkeys

All operations are exposed through the `recast` CLI and the `px-recast` IPC target for Hyprland:

### Hyprland (`hyprland.conf`)
```conf
bind = SUPER+ALT, R, exec, ~/.local/bin/recast toggle            # Start / stop recording
bind = SUPER+ALT, S, exec, ~/.local/bin/recast saveReplay        # Save instant replay clip
bind = SUPER+ALT, P, exec, ~/.local/bin/recast pause             # Pause / resume recording
bind = SUPER+ALT, O, exec, ~/.local/bin/recast openClip          # Open last recorded clip
```

### Omarchy Lua (`bindings.lua`)
```lua
o.bind("SUPER + ALT + R", "Toggle screen recording", "~/.local/bin/recast toggle")
o.bind("SUPER + ALT + S", "Save replay clip", "~/.local/bin/recast saveReplay")
o.bind("SUPER + ALT + P", "Pause or resume recording", "~/.local/bin/recast pause")
o.bind("SUPER + ALT + O", "Open the last clip", "~/.local/bin/recast openClip")
```

### CLI Commands
```bash
recast toggle                      # Toggle recording state
recast record                      # Start recording
recast stop                        # Stop recording
recast pause                       # Pause recording
recast resume                      # Resume recording
recast saveReplay                  # Save instant replay buffer
recast openClip                    # Open the last saved clip in default player
recast openFolder                  # Open destination folder
recast trim 00:05 00:30 [precise]  # Trim the last saved clip
recast status                      # Return JSON status snapshot
```

---

## ⚙️ Settings Reference

Settings are stored in `~/.config/omarchy/shell.json` under `pix.recast` and can be adjusted directly from the settings panel:

| Setting Key | Default | Description |
| :--- | :--- | :--- |
| `minFreeDiskMb` | `2000` | Disk space safety floor in MB; prevents recording if free space drops below threshold. |
| `fileNameTemplate` | `screenrecording-%Y%m%d_%H%M%S` | Custom output file name template with strftime tokens. |
| `organizeByDate` | `false` | Automatically group recordings into subfolders formatted as `YYYY-MM-DD/`. |
| `container` | `mkv` | Output container format (`mkv` recommended for crash safety, `mp4`). |
| `countdown` | `3` | Pre-roll countdown seconds (`0` = Off, `3`, `5`, `10`). |
| `mode` | `record` | Active operation mode: `record`, `stream`, or `replay`. |
| `osdEnabled` | `true` | Show floating on-screen recording badge overlay. |
| `osdPosition` | `top-right` | Corner placement for on-screen badge (`top-right`, `top-center`, `bottom-right`). |
| `replaySeconds` | `60` | Duration of circular instant replay buffer in seconds. |
| `replayStorage` | `ram` | Replay buffer storage location (`ram` for memory, `disk` for storage drive). |

---

## 🏗️ Performance & Architecture

- **0.0% Idle CPU**: Better Recast maintains absolute dormancy at rest. All state notifications are event-driven or lazily refreshed when the control panel is opened.
- **Direct GPU Framebuffer Capture**: Video frames are captured directly on the graphics card and encoded via hardware ASIC engines, keeping system CPU utilization under 3%.
- **Secure Credentials Handling**: RTMP stream keys are injected into GSR via environment variables in memory, never exposed via `/proc/<pid>/cmdline` or logged to disk.
- **Crash Resilience**: Defaulting to the Matroska (`.mkv`) container ensures that videos remain playable even if games crash or power drops mid-capture.

---

## 🤝 Contributing

Contributions, bug reports, and pull requests are welcome! Please read our [Contributing Guidelines](CONTRIBUTING.md) and [Code of Conduct](SECURITY.md) before submitting code.

Run automated smoke tests before submitting pull requests:
```bash
omarchy plugin validate .
bash tests/smoke.sh
```

---

## 📄 License

Licensed under the [MIT License](LICENSE). Built with ❤️ by [pxllbt](https://github.com/pxllbt).
