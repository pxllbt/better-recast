# Contributing to Better Recast

Thank you for your interest in improving Better Recast! Whether you're adding support for new hardware, refining the user interface, or optimizing performance, contributions are welcome.

---

## 🛠️ Development Setup

### Prerequisites
- **Linux on Wayland** (Hyprland recommended)
- **Quickshell** `0.3.0+`
- **gpu-screen-recorder** `6.0.0+`
- **Node.js** `20+` (for automated unit and smoke tests)
- **Python** `3.10+` (for GSR socket IPC bridge)

### Running from Source
Link or clone directly into your Omarchy plugins directory:

```bash
cd ~/.config/omarchy/plugins/pix.recast
omarchy plugin enable pix.recast
```

---

## ⚡ Core Principles

1. **Zero Idle Overhead**:
   Better Recast strictly maintains **0.0% CPU at idle**.
   - State files must be read lazily or with lightweight timers only when surfaces are open.
   - Avoid infinite loops, busy waits, or continuous unconstrained polling.
   - Subprocesses must be re-armed safely and cleaned up on exit.

2. **Hardware First**:
   - Prefer GPU hardware encoders (NVENC on NVIDIA, VAAPI on AMD/Intel) over software CPU encoding.
   - Always validate hardware capabilities before launching recording sessions.

3. **Crash Safety**:
   - Default to container formats that survive ungraceful termination (MKV).
   - Guard against out-of-disk conditions before capture begins.

---

## 🧪 Running Tests

Always run the full test suite before submitting a pull request:

```bash
bash tests/smoke.sh
```

All 21 test suites must report green before merging.

---

## 📝 Pull Request Guidelines

1. **Clear Commit Messages**: Use concise, imperative commit messages (e.g. `Fix recording toggle re-arm and allow stop during starting state`).
2. **Performance Validation**: Ensure idle CPU remains at ~0.0% and recording uses hardware acceleration.
3. **Keep PRs Focused**: Avoid bundling unrelated refactorings into a single PR.
