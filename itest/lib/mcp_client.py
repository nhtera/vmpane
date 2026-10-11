"""A scripted MCP client for the itests: starts `vmpane mcp`, speaks newline-delimited JSON-RPC over its stdio."""
import json
import subprocess
import threading
import queue


class MCPClient:
    def __init__(self, vmpane, env=None, version="2025-06-18"):
        self.proc = subprocess.Popen([vmpane, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env, text=True)
        self.messages = queue.Queue()
        self.next_id = 1
        threading.Thread(target=self._read, daemon=True).start()
        hello = self.request("initialize", {"protocolVersion": version, "clientInfo": {"name": "itest-mcp", "version": "1"},
                                            "capabilities": {}})
        assert hello["result"]["protocolVersion"] == version, hello
        self.notify("notifications/initialized", {})

    def _read(self):
        for line in self.proc.stdout:
            self.messages.put(json.loads(line))

    def send(self, message):
        self.proc.stdin.write(json.dumps(message) + "\n")
        self.proc.stdin.flush()

    def notify(self, method, params):
        self.send({"jsonrpc": "2.0", "method": method, "params": params})

    def start(self, method, params):
        request_id = self.next_id
        self.next_id += 1
        self.send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
        return request_id

    def wait(self, request_id, timeout=120):
        pending = []
        try:
            while True:
                message = self.messages.get(timeout=timeout)
                if message.get("id") == request_id:
                    return message
                pending.append(message)
        finally:
            for message in pending:
                self.messages.put(message)

    def request(self, method, params, timeout=120):
        return self.wait(self.start(method, params), timeout)

    def call(self, tool, **arguments):
        """The tool's result (content, structuredContent, isError)."""
        answer = self.request("tools/call", {"name": tool, "arguments": arguments}, timeout=300)
        assert "result" in answer, answer
        return answer["result"]

    def close(self):
        self.proc.stdin.close()
        self.proc.wait(timeout=10)
