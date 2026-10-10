"""Runs one QMP command against a QEMU monitor socket and prints its "return" value as JSON.

Usage: qmp.py <socket> <command> [<arguments as JSON>]
"""

from __future__ import annotations  # /usr/bin/python3 is 3.9

import json
import socket
import sys


def main() -> int:
    path, command = sys.argv[1], sys.argv[2]
    arguments = json.loads(sys.argv[3]) if len(sys.argv) > 3 else None
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(10)
        s.connect(path)
        stream = s.makefile("rwb")

        def send(execute: str, args: dict | None = None) -> dict:
            message = {"execute": execute}
            if args is not None:
                message["arguments"] = args
            stream.write(json.dumps(message).encode() + b"\n")
            stream.flush()
            while True:  # skip asynchronous events
                reply = json.loads(stream.readline())
                if "return" in reply or "error" in reply:
                    return reply

        json.loads(stream.readline())  # greeting
        send("qmp_capabilities")
        reply = send(command, arguments)
    if "error" in reply:
        print(json.dumps(reply["error"]), file=sys.stderr)
        return 1
    print(json.dumps(reply["return"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
