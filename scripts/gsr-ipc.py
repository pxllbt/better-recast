#!/usr/bin/env python3
"""pix.recast IPC client — sends commands to gpu-screen-recorder via unix socket.

Usage:
    gsr-ipc.py <socket_path> <command> [args...]

Commands (the set Service.qml actually sends):
    set-paused      Pause (true) or unpause (false) — requires argument
    stop            Stop and save recording (replay mode: stop WITHOUT save)
    save-replay     Save the replay buffer (replay mode). Optional seconds arg;
                    omitting it saves the whole buffer. Prints the saved file path

Prints the saved path (save-replay) or "ok" on success, and exits non-zero with
"error: ..." on stderr otherwise — Service.qml parses that output verbatim.
"""

import socket
import sys
import json

MAX_BUF = 65536


def main():
    if len(sys.argv) < 3:
        print("Usage: gsr-ipc.py <socket_path> <command> [args...]", file=sys.stderr)
        sys.exit(1)

    socket_path = sys.argv[1]
    command = sys.argv[2]
    request_id = 1

    # Build the request
    data = None
    if command == "set-paused":
        if len(sys.argv) < 4:
            print("error: set-paused requires true|false", file=sys.stderr)
            sys.exit(1)
        arg = sys.argv[3].lower()
        data = arg in ("true", "1", "yes")
    elif command == "stop":
        pass  # no data needed
    elif command == "save-replay" and len(sys.argv) >= 4:
        try:
            seconds = int(sys.argv[3])
            data = {"seconds": seconds}
        except ValueError:
            pass
    else:
        print("error: unknown command: " + str(command), file=sys.stderr)
        sys.exit(1)

    request = {"id": request_id, "name": command}
    if data is not None:
        request["data"] = data

    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(10.0)
        s.connect(socket_path)
        s.sendall(json.dumps(request).encode() + b"\n")

        # Read reply (may be multi-line, find matching id)
        # Cap buffer to prevent unbounded growth from a slow/stuck peer.
        buf = b""
        while True:
            chunk = s.recv(4096)
            if not chunk:
                break
            if len(buf) + len(chunk) > MAX_BUF:
                s.close()
                print("error: reply too large", file=sys.stderr)
                sys.exit(1)
            buf += chunk
            # Only whole lines are parsed: a chunk boundary can split a line —
            # and a multi-byte UTF-8 sequence with it, which decode() would raise
            # on. Decode leniently and hold the trailing partial line back.
            text = buf.decode("utf-8", errors="replace")
            lines = text.split("\n")
            buf = lines.pop().encode("utf-8", errors="replace")
            for line in lines:
                line = line.strip()
                if not line:
                    continue
                try:
                    reply = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if reply.get("id") != request_id:
                    continue
                s.close()
                if reply.get("result") == "ok":
                    result_data = reply.get("data", "")
                    if result_data:
                        print(result_data)
                    else:
                        print("ok")
                    sys.exit(0)
                else:
                    err = reply.get("data", "unknown error")
                    print("error: " + str(err), file=sys.stderr)
                    sys.exit(1)
        s.close()
        print("error: no reply from gsr", file=sys.stderr)
        sys.exit(1)
    except (socket.error, OSError) as e:
        print("error: " + str(e), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
