# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 1.3.x   | :white_check_mark: |
| < 1.3   | :x:                |

## Security Model

Better Recast executes hardware capture commands via `gpu-screen-recorder` and performs system audio routing via `wpctl`. To maintain strict system security:

1. **Credentials Isolation**: Stream keys for RTMP broadcasts are held strictly in memory during the session and passed to GSR via the `GSR_AUTH` environment variable. They are **never** written to command-line arguments (preventing visibility in `/proc/<pid>/cmdline`), and are never persisted to disk unless explicitly opted into.
2. **Path Sanitization**: Custom output directories, filenames, and trim tool parameters are properly escaped and passed via structured argv arrays, avoiding arbitrary shell command injection.
3. **IPC Scoping**: Unix socket communications use user-scoped runtime directories (`$XDG_RUNTIME_DIR/px-gsr/`).

## Reporting a Vulnerability

If you discover a security vulnerability in Better Recast, please report it responsibly:

1. **Do not open a public issue.**
2. Send an email to the repository maintainer via their GitHub profile or open a private advisory at [GitHub Security Advisories](https://github.com/pxllbt/better-recast/security/advisories/new).
3. Include detailed steps to reproduce the issue and any relevant system logs.

We appreciate your efforts in keeping Better Recast secure for all users.
