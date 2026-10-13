# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.3.0] - 2026-10-13

### Added
- **Dynamic Better Bar Integration**: Real-time REC and PAUSED dynamic island chip in Better Bar with elapsed time and pre-roll countdown.
- **Hardware-Accelerated Encoding**: Automatic encoder detection for NVIDIA (NVENC), AMD (VAAPI), and Intel (QuickSync / VAAPI) with HEVC/H.264/AV1 support.
- **Pre-Roll Countdown**: Configurable 3, 5, or 10-second countdown with live chip ticking and in-place notifications.
- **Instant Replay Mode**: Circular memory buffer capture allowing retro-active saving of gameplay moments via hotkey (**S**).
- **Disk-Space Safety Guard**: Minimum free disk space floor (`minFreeDiskMb`) preventing captures from crashing on full partitions.
- **Post-Recording Trim Tool**: Fast stream copy and frame-accurate trimming powered by FFmpeg directly in the panel.
- **Recent Recordings Carousel**: Fast access to recent clips with single-click folder open and path copy actions.
- **Preset Configurations & Named Regions**: Saved capture geometries and per-activity encoding profiles.
- **Per-Application Audio Routing**: Isolate specific application audio streams using `gpu-screen-recorder` application audio endpoints.

### Changed
- **Crash-Safe Container Default**: Defaulted container output to MKV across all presets and recording profiles.
- **Elapsed Timer Anchoring**: Re-anchored base time calculations so paused intervals are accurately excluded and new takes begin at `00:00`.
- **Zero-CPU Idle Architecture**: Replaced expensive continuous process polling with lazy, event-driven state snapshots.

### Fixed
- **Process Re-arming**: Fixed Quickshell process re-arming on repeated click toggles.
- **Subprocess Clean Termination**: Ensured background GSR and socket IPC processes terminate cleanly on stop.
- **GPU Info Probe Overhead**: Eliminated redundant GPU info re-probing when opening the settings panel.
