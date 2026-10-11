#!/usr/bin/env python3
"""Runs a command in the guest through the helper's agent.exec and relays its output.

Usage: agent_exec.py <socket> [--user] [--timeout-ms N] <shell command>
Runs as admin (root) unless --user. Writes the guest's stdout/stderr to ours and exits with the guest's exit
code; 128+n after a signal, 124 on a guest timeout, 125 when the request failed.
"""
import base64
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from helper_socket import HelperConnection  # noqa: E402


def main():
    args = sys.argv[1:]
    path = args.pop(0)
    params = {"as": "admin"}
    while args and args[0].startswith("--"):
        flag = args.pop(0)
        if flag == "--user":
            params["as"] = "user"
        elif flag == "--timeout-ms":
            params["timeoutMs"] = int(args.pop(0))
    params["shell"] = " ".join(args)
    with HelperConnection(path) as sock:
        file = sock

        def send(request_id, method, request_params):
            message = {"jsonrpc": "2.0", "id": request_id, "method": method, "params": request_params}
            sock.sendall((json.dumps(message) + "\n").encode())

        send(0, "helper.hello", {"proto": 1, "minProto": 1, "client": {"name": "itest", "version": "0", "kind": "cli"}})
        send(1, "agent.exec", params)
        exec_id = None
        for line in file:
            message = json.loads(line)
            if message.get("id") == 0:
                continue
            if message.get("id") == 1:
                if "error" in message:
                    print(json.dumps(message["error"]), file=sys.stderr)
                    return 125
                exec_id = message["result"]["execId"]
                continue
            note = message.get("params", {})
            if message.get("method") == "exec.output" and note.get("execId") == exec_id:
                out = sys.stdout if note["stream"] == "stdout" else sys.stderr
                out.buffer.write(base64.b64decode(note["dataB64"]))
                out.flush()
            elif message.get("method") == "exec.exited" and note.get("execId") == exec_id:
                if note.get("timedOut"):
                    return 124
                if note.get("code") is not None:
                    return note["code"]
                return 128 + 9 if note.get("signal") == "SIGKILL" else 129
    return 125


if __name__ == "__main__":
    sys.exit(main())
