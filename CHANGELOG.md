# Changelog

All notable changes documented here. Format loosely follows [Keep a Changelog](https://keepachangelog.com/), SemVer for versions.

## 1.3.0 — 2026-10-13

### Added
- Dynamic Better Bar integration — live REC and PAUSED chip with elapsed time and countdown
- Hardware-accelerated encoding with auto-detection (NVENC, VAAPI, QuickSync)
- Pre-roll countdown (3/5/10 seconds) with chip ticking
- Instant replay mode — circular buffer, save last 15s to 20min with a keypress
- Disk-space safety guard (`minFreeDiskMb`) — won't crash on a full drive
- Post-recording trim tool — stream copy or frame-accurate FFmpeg cut from the panel
- Recent recordings carousel — quick access with folder open and path copy
- Preset configurations and saved capture regions
- Per-application audio routing

### Changed
- Default container is now MKV (crash-safe) across all presets
- Elapsed timer anchored properly — paused time excluded, new takes start at 00:00
- Replaced continuous process polling with lazy, event-driven state snapshots

### Fixed
- Process re-arming on repeated click toggles
- Background GSR and socket IPC processes terminate cleanly on stop
- GPU info re-probing removed when opening settings panel