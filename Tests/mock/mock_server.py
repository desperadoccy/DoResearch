"""Mock model server for tests: speaks OpenAI Chat Completions and Anthropic Messages.

Behavior is scripted from the conversation so the tool loop can be exercised end to end:
- no tool result yet  -> call list_projects (or `ping` if offered)
- after a tool result -> final text answer echoing what it saw
Every request body is appended to requests.jsonl for assertions.
Usage: python3 -I mock_server.py PORT LOGDIR
"""
import json, sys, os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT, LOGDIR = int(sys.argv[1]), sys.argv[2]
LOG = os.path.join(LOGDIR, "requests.jsonl")


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.startswith("/v1/models"):
            if self.headers.get("x-api-key") is not None or self.headers.get("anthropic-version"):
                return self.send(200, {"data": [{"id": "mock-claude"}]})
            return self.send(200, {"object": "list", "data": [{"id": "mock-gpt-b"}, {"id": "mock-gpt-a"}]})
        self.send(404, {"error": {"message": "no route"}})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["content-length"])))
        with open(LOG, "a") as f:
            f.write(json.dumps({"path": self.path, "headers": dict(self.headers), "body": body}) + "\n")
        model = body.get("model", "")
        if model == "bad-model":
            return self.send(404, {"error": {"message": f"model '{model}' not found"}})
        if self.path == "/v1/chat/completions":
            return self.openai(body)
        if self.path == "/v1/messages":
            return self.anthropic(body)
        self.send(404, {"error": {"message": "no route"}})

    def openai(self, body):
        msgs = body["messages"]
        tools = [t["function"]["name"] for t in body.get("tools", [])]
        last = msgs[-1]
        if last["role"] == "tool":
            msg = {"role": "assistant", "content": f"<think>hidden</think>Saw tool result: {last['content'][:60]}"}
            return self.send(200, {"model": body["model"], "choices": [{"message": msg, "finish_reason": "stop"}]})
        name = "ping" if "ping" in tools else "list_projects"
        args = {"message": "ok"} if name == "ping" else {}
        msg = {"role": "assistant", "content": None,
               "tool_calls": [{"id": "call_mock1", "type": "function",
                               "function": {"name": name, "arguments": json.dumps(args)}}]}
        # finish_reason "stop" with tool calls: some servers do this; the client must still run the tools.
        self.send(200, {"model": body["model"], "choices": [{"message": msg, "finish_reason": "stop"}]})

    def anthropic(self, body):
        msgs = body["messages"]
        last = msgs[-1]
        content = last["content"] if isinstance(last["content"], list) else []
        results = [b for b in content if b.get("type") == "tool_result"]
        if results:
            out = [{"type": "thinking", "thinking": "", "signature": "sig-final"},
                   {"type": "text", "text": f"Claude saw: {str(results[0]['content'])[:60]}"}]
            return self.send(200, {"model": body["model"], "content": out, "stop_reason": "end_turn"})
        names = [t["name"] for t in body.get("tools", [])]
        name = "ping" if "ping" in names else "list_projects"
        out = [{"type": "thinking", "thinking": "", "signature": "sig-1"},
               {"type": "tool_use", "id": "toolu_mock1", "name": name,
                "input": {"message": "ok"} if name == "ping" else {}}]
        self.send(200, {"model": body["model"], "content": out, "stop_reason": "tool_use"})


ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
