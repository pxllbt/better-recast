# Security Policy

## Supported versions

| Version | Status |
| --- | --- |
| 1.3.x   | Current, receiving updates |

## Keeping your recordings safe

Better Recast runs `gpu-screen-recorder` and uses `wpctl` for audio routing. Here's what the security model looks like:

- **Stream keys stay in memory.** RTMP keys go through the `GSR_AUTH` env var, never appear in `/proc/<pid>/cmdline`, and aren't persisted to disk unless you explicitly opt in.
- **No shell injection.** Filenames, output dirs, and trim parameters go through structured argv arrays, not raw shell strings.
- **Scoped IPC.** Unix socket communications live in `$XDG_RUNTIME_DIR/px-gsr/`.

## Reporting

Don't open a public issue for anything security-sensitive. [Open a private advisory](https://github.com/pxllbt/better-recast/security/advisories/new) or message me on GitHub — include repro steps and relevant logs.

Thanks for keeping users safe.