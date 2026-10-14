#!/usr/bin/env bash
# Better Recast Diagnostic & Self-Repair Engine
# Checks hardware encoders, DRM render nodes, PipeWire microphone levels, and portal responsiveness.
set -uo pipefail

DO_FIX=false
DO_TEST=false
DO_JSON=false
DO_REPORT=false

for arg in "$@"; do
    case "$arg" in
        --fix) DO_FIX=true ;;
        --test) DO_TEST=true ;;
        --json) DO_JSON=true ;;
        --report) DO_REPORT=true ;;
        -h|--help)
            echo "Usage: recast-doctor.sh [--fix] [--test] [--json] [--report]"
            echo "  --fix     Automatically repair detected issues (reap zombies, unlink dead sockets, unmute mic)"
            echo "  --test    Execute a 2-second headless test recording to verify hardware encode pipeline"
            echo "  --json    Emit machine-readable JSON status"
            echo "  --report  Emit sanitized Markdown summary for GitHub issues"
            exit 0
            ;;
    esac
done

ISSUES=0
FIXED=0
declare -A RESULTS

# 1. GPU & DRM Render Node Access
render_nodes=$(ls /dev/dri/renderD* 2>/dev/null || echo "")
if [ -n "$render_nodes" ]; then
    accessible_node=""
    for node in $render_nodes; do
        if [ -r "$node" ] && [ -w "$node" ]; then
            accessible_node="$node"
            break
        fi
    done
    if [ -n "$accessible_node" ]; then
        RESULTS["render_node"]="PASS ($accessible_node read/write accessible)"
    else
        RESULTS["render_node"]="FAIL (render nodes found but lack read/write permissions)"
        ISSUES=$((ISSUES + 1))
    fi
else
    RESULTS["render_node"]="WARN (no /dev/dri/renderD* nodes found; software fallback only)"
fi

# 2. Hardware Encoders
if command -v gpu-screen-recorder >/dev/null 2>&1; then
    gsr_info=$(gpu-screen-recorder --info 2>/dev/null || echo "")
    if echo "$gsr_info" | grep -qE "hevc|h264"; then
        codecs=$(echo "$gsr_info" | grep -A5 "section=video_codecs" | grep -v "section=" | tr '\n' ' ' | xargs)
        RESULTS["encoders"]="PASS (${codecs:-hevc/h264})"
    else
        RESULTS["encoders"]="WARN (gpu-screen-recorder found, but no hardware codecs detected)"
    fi
else
    RESULTS["encoders"]="FAIL (gpu-screen-recorder binary not found in PATH)"
    ISSUES=$((ISSUES + 1))
fi

# 3. Microphone Volume Sanity
if command -v wpctl >/dev/null 2>&1; then
    mic_vol=$(wpctl get-volume @DEFAULT_AUDIO_SOURCE@ 2>/dev/null | awk '{print $2}' || echo "")
    if [ -n "$mic_vol" ]; then
        if [ "$mic_vol" = "0.00" ] || [ "$mic_vol" = "0" ]; then
            RESULTS["microphone"]="FAIL (microphone is muted at 0.00 volume)"
            ISSUES=$((ISSUES + 1))
            if [ "$DO_FIX" = true ]; then
                wpctl set-volume @DEFAULT_AUDIO_SOURCE@ 0.80 2>/dev/null || true
                FIXED=$((FIXED + 1))
                RESULTS["microphone"]="FIXED (unmuted microphone to 0.80)"
            fi
        else
            RESULTS["microphone"]="PASS (volume $mic_vol)"
        fi
    else
        RESULTS["microphone"]="SKIP (no default audio source found)"
    fi
else
    RESULTS["microphone"]="SKIP (wpctl not available)"
fi

# 4. Process & IPC Socket Hygiene
orphans=$(pgrep -x gpu-screen-recorder 2>/dev/null || echo "")
ipc_sock="${XDG_RUNTIME_DIR:-/tmp}/px-gsr/ipc.sock"

if [ -n "$orphans" ]; then
    RESULTS["processes"]="WARN (detached recorder process running: $orphans)"
    if [ "$DO_FIX" = true ]; then
        for pid in $orphans; do
            kill -2 "$pid" 2>/dev/null || true
            sleep 1
            kill -9 "$pid" 2>/dev/null || true
            FIXED=$((FIXED + 1))
        done
        RESULTS["processes"]="FIXED (reaped orphan processes: $orphans)"
    fi
else
    RESULTS["processes"]="PASS (clean, no zombie processes)"
fi

if [ -e "$ipc_sock" ]; then
    # Test if socket is actively listening
    if ! command -v nc >/dev/null 2>&1 || ! nc -z -U "$ipc_sock" >/dev/null 2>&1; then
        if [ "$DO_FIX" = true ]; then
            rm -f "$ipc_sock" 2>/dev/null || true
            FIXED=$((FIXED + 1))
            RESULTS["ipc_socket"]="FIXED (unlinked dead socket)"
        else
            RESULTS["ipc_socket"]="WARN (stale socket file at $ipc_sock)"
        fi
    else
        RESULTS["ipc_socket"]="PASS (active socket)"
    fi
else
    RESULTS["ipc_socket"]="PASS (clean)"
fi

# 5. Pre-flight Test Probe (--test)
if [ "$DO_TEST" = true ]; then
    if command -v gpu-screen-recorder >/dev/null 2>&1; then
        test_clip="/tmp/recast-preflight-test.mkv"
        rm -f "$test_clip"
        timeout 3 gpu-screen-recorder -w portal -f 30 -o "$test_clip" >/dev/null 2>&1 || true
        if [ -s "$test_clip" ]; then
            RESULTS["preflight_probe"]="PASS (2s test capture succeeded, $(stat -c%s "$test_clip") bytes)"
            rm -f "$test_clip"
        else
            RESULTS["preflight_probe"]="WARN (test probe did not capture frames)"
        fi
    fi
fi

# 6. Output Formats
if [ "$DO_JSON" = true ]; then
    printf '{\n'
    printf '  "issues": %d,\n' "$ISSUES"
    printf '  "fixed": %d,\n' "$FIXED"
    printf '  "results": {\n'
    first=true
    for k in "${!RESULTS[@]}"; do
        if [ "$first" = true ]; then first=false; else printf ',\n'; fi
        printf '    "%s": "%s"' "$k" "${RESULTS[$k]}"
    done
    printf '\n  }\n}\n'
    exit 0
fi

if [ "$DO_REPORT" = true ]; then
    echo "## Better Recast Diagnostic Report"
    echo "- **Generated:** $(date -u +'%Y-%m-%d %H:%M:%SZ')"
    echo "- **Kernel:** $(uname -r)"
    echo "- **DRM Nodes:** $(ls /dev/dri/renderD* 2>/dev/null | tr '\n' ' ')"
    echo ""
    echo "### Subsystem Health"
    for k in "${!RESULTS[@]}"; do
        echo "- **$k**: ${RESULTS[$k]}"
    done
    exit 0
fi

echo "=== Better Recast Doctor ==="
for k in "${!RESULTS[@]}"; do
    printf "  %-18s: %s\n" "$k" "${RESULTS[$k]}"
done
echo "-----------------------------------"
if [ "$ISSUES" -eq 0 ]; then
    echo "All systems healthy! (0 issues detected)"
    exit 0
elif [ "$FIXED" -gt 0 ] && [ "$FIXED" -ge "$ISSUES" ]; then
    echo "Auto-repair successful ($FIXED issue(s) fixed)"
    exit 0
else
    echo "Detected $ISSUES issue(s). Run with --fix to automatically repair."
    exit 1
fi
