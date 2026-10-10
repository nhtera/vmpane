#!/usr/bin/env python3
"""Minimal control-socket client for integration scenarios.

Usage: rpc.py <socket> <method> [params-json] [--repeat N]
Prints the result as JSON (exit 0) or the error (exit 1). With --repeat, prints the median
round-trip time in milliseconds of N calls instead.
"""
import json
import socket
import statistics
import sys
import time


def call(sock, file, request_id, method, params):
    message = {"jsonrpc": "2.0", "id": request_id, "method": method}
    if params is not None:
        message["params"] = params
    sock.sendall((json.dumps(message) + "\n").encode())
    return json.loads(file.readline())


def main():
    args = sys.argv[1:]
    repeat = 0
    if "--repeat" in args:
        index = args.index("--repeat")
        repeat = int(args[index + 1])
        del args[index:index + 2]
    path, method = args[0], args[1]
    params = json.loads(args[2]) if len(args) > 2 else None
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.connect(path)
        file = sock.makefile("r")
        hello = call(sock, file, 0, "helper.hello",
                     {"proto": 1, "minProto": 1, "client": {"name": "itest", "version": "0", "kind": "cli"}})
        if "error" in hello:
            print(json.dumps(hello["error"]))
            return 1
        if repeat:
            times = []
            for i in range(repeat):
                start = time.perf_counter()
                call(sock, file, i + 1, method, params)
                times.append((time.perf_counter() - start) * 1000)
            print(f"{statistics.median(times):.2f}")
            return 0
        response = call(sock, file, 1, method, params)
        if "error" in response:
            print(json.dumps(response["error"]))
            return 1
        print(json.dumps(response["result"]))
        return 0


if __name__ == "__main__":
    sys.exit(main())
