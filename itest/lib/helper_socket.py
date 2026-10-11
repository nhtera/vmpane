"""A connection to a helper's control socket for the itest clients. Through the itest bridge
(VMPANE_ITEST_BRIDGE, built by scripts/itest.sh) when it is set, so helpers that enforce policy see the
app.vmpane.mac.itest signature; straight to the socket otherwise."""
import io
import os
import socket
import subprocess


class HelperConnection:
    def __init__(self, path):
        bridge = os.environ.get("VMPANE_ITEST_BRIDGE")
        self.proc = None
        self.sock = None
        if bridge:
            self.proc = subprocess.Popen([bridge, path], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
            self.reader = io.TextIOWrapper(self.proc.stdout, encoding="utf-8")
        else:
            self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.sock.connect(path)
            self.reader = self.sock.makefile("r")

    def sendall(self, data):
        if self.proc:
            self.proc.stdin.write(data)
            self.proc.stdin.flush()
        else:
            self.sock.sendall(data)

    def readline(self):
        return self.reader.readline()

    def __iter__(self):
        return iter(self.reader)

    def close(self):
        if self.proc:
            try:
                self.proc.stdin.close()
            except OSError:
                pass
            self.proc.wait(timeout=10)
        else:
            self.sock.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
