# Contributing to Better Recast

Thanks for helping improve the recorder. Whether you're adding GPU support, refining the UI, or tuning performance, contributions are welcome.

## Setup

You'll need:
- Linux on Wayland (Hyprland recommended)
- Quickshell 0.3.0+
- gpu-screen-recorder 6.0.0+
- Node.js 20+ (for tests)
- Python 3.10+ (for GSR socket IPC bridge)

```bash
# Development: link or clone into your Omarchy plugins
cd ~/.config/omarchy/plugins/pix.recast
omarchy plugin enable pix.recast
```

## What to keep in mind

1. **Idle CPU.** Better Recast stays near 0% CPU at idle. State reads happen lazily or on event, never on a 1s poll loop. No infinite loops, no busy waits.
2. **Hardware first.** Prefer GPU encoders (NVENC on NVIDIA, VAAPI on AMD/Intel) over software. Always check what the GPU reports before launching a capture.
3. **Crash safety.** Default to MKV (its index is written incrementally, so an interrupted capture stays recoverable). Guard against out-of-disk before capture starts.

## Tests

```bash
bash tests/smoke.sh
```

All 21 suites should pass.

## PRs

- Describe what changed and why
- Check idle CPU stays near 0 and recording uses hardware acceleration
- Keep PRs focused — one bug or feature per PR