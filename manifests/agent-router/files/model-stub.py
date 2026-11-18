"""Serve a deterministic Anthropic-compatible model for repeatable sandbox demos."""
import json
import re
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODEL = "sandbox-stub"
HELP = ("I'm the sandbox stub model (no real LLM). Try: \"echo hello\", \"add 2 and 3\" or \"show the environment\". "
        "I call the matching tool if this agent has it.")


def text_of(content):
    if isinstance(content, str):
        return content
    pieces = []
    for block in content or ():
        if isinstance(block, dict) and block.get("type") == "text":
            pieces.append(block.get("text", ""))
    return " ".join(pieces)


def find_tool(tools, *suffixes):
    for tool in tools:
        letters = re.sub("[^a-z]", "", tool.get("name", "").lower())
        if letters.endswith(suffixes):
            return tool
    return None


def props(tool, types):
    schema = tool.get("input_schema") or {}
    return [
        name for name, definition in (schema.get("properties") or {}).items()
        if definition.get("type") in types
    ]


def plan(user_text, tools):
    """Find a matching tool and derive its arguments from a demo prompt."""
    lower = user_text.lower()
    if re.search(r"\benv", lower):
        environment = find_tool(tools, "getenv", "env")
        if environment:
            return environment, {}

    numbers = re.findall(r"-?\d+(?:\.\d+)?", user_text)
    if len(numbers) >= 2 and re.search(r"\b(sum|add|plus)\b|\+", lower):
        addition = find_tool(tools, "getsum", "sum", "add")
        if addition:
            argument_names = props(addition, ("number", "integer")) or ["a", "b"]
            values = (float(number) if "." in number else int(number) for number in numbers)
            return addition, dict(zip(argument_names, values))

    echo = find_tool(tools, "echo")
    if echo and re.search(r"\becho\b", lower):
        arguments = props(echo, ("string",)) or ["message"]
        prefix = re.match(r"(?i)^.*?\becho\b[:\s]*", user_text)
        message = (user_text[prefix.end():] if prefix else user_text).strip()
        return echo, {arguments[0]: message or "hello"}
    return None


def respond(req):
    """Return (content blocks, stop_reason)."""
    msgs, tools = req.get("messages") or [], req.get("tools") or []
    last = msgs[-1] if msgs else {"role": "user", "content": ""}
    blocks = last.get("content") if isinstance(last.get("content"), list) else []
    results = [b for b in blocks if isinstance(b, dict) and b.get("type") == "tool_result"]
    if results:
        names = {b.get("id"): b.get("name") for m in msgs if m.get("role") == "assistant"
                 for b in (m.get("content") if isinstance(m.get("content"), list) else []) if b.get("type") == "tool_use"}
        lines = []
        for r in results:
            name, body = names.get(r.get("tool_use_id"), "the tool"), text_of(r.get("content")).strip()
            try:   # kagent reports a failed MCP call as a normal result: {"error": "...", "isError": true}
                parsed = json.loads(body)
                failed = isinstance(parsed, dict) and bool(parsed.get("isError"))
            except ValueError:
                failed = False
            if r.get("is_error") or failed:
                lines.append(f"The call to `{name}` was refused or failed: {body or '(no details)'}")
            else:
                lines.append(f"`{name}` returned: {body[:2000]}")
        return [{"type": "text", "text": "\n".join(lines)}], "end_turn"
    picked = plan(text_of(last.get("content")), tools)
    if picked:
        tool, args = picked
        return [{"type": "tool_use", "id": "toolu_" + uuid.uuid4().hex[:24], "name": tool["name"], "input": args}], "tool_use"
    return [{"type": "text", "text": HELP}], "end_turn"


def sse(event, data):
    return f"event: {event}\ndata: {json.dumps(data)}\n\n".encode()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def send_json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.send_json(200, {"ok": True}) if self.path == "/healthz" else self.send_json(404, {"error": "not found"})

    def do_POST(self):
        try:
            req = json.loads(self.rfile.read(int(self.headers.get("content-length") or 0)) or b"{}")
        except ValueError:
            return self.send_json(400, {"type": "error", "error": {"type": "invalid_request_error", "message": "bad JSON"}})
        if self.path.split("?")[0].endswith("/count_tokens"):
            return self.send_json(200, {"input_tokens": len(json.dumps(req)) // 4})
        if not self.path.split("?")[0].endswith("/messages"):
            return self.send_json(404, {"type": "error", "error": {"type": "not_found_error", "message": self.path}})
        content, stop = respond(req)
        usage_in, usage_out = len(json.dumps(req.get("messages", []))) // 4, len(json.dumps(content)) // 4
        tool = next((b["name"] for b in content if b["type"] == "tool_use"), "-")
        print(json.dumps({"stream": bool(req.get("stream")), "stop": stop, "tool": tool,
                          "offered": [t.get("name") for t in req.get("tools") or []][:20],
                          "actor": self.headers.get("x-ate-actor", "-")}), flush=True)
        msg = {"id": "msg_" + uuid.uuid4().hex[:24], "type": "message", "role": "assistant", "model": req.get("model", MODEL),
               "stop_reason": stop, "stop_sequence": None, "usage": {"input_tokens": usage_in, "output_tokens": usage_out}}
        if not req.get("stream"):
            return self.send_json(200, {**msg, "content": content})
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.send_header("connection", "close")
        self.end_headers()
        out = [sse("message_start", {"type": "message_start", "message": {**msg, "content": [], "stop_reason": None,
                                                                            "usage": {"input_tokens": usage_in, "output_tokens": 1}}})]
        for i, b in enumerate(content):
            if b["type"] == "text":
                out += [sse("content_block_start", {"type": "content_block_start", "index": i, "content_block": {"type": "text", "text": ""}}),
                        sse("content_block_delta", {"type": "content_block_delta", "index": i, "delta": {"type": "text_delta", "text": b["text"]}})]
            else:
                out += [sse("content_block_start", {"type": "content_block_start", "index": i,
                                                    "content_block": {"type": "tool_use", "id": b["id"], "name": b["name"], "input": {}}}),
                        sse("content_block_delta", {"type": "content_block_delta", "index": i,
                                                    "delta": {"type": "input_json_delta", "partial_json": json.dumps(b["input"])}})]
            out.append(sse("content_block_stop", {"type": "content_block_stop", "index": i}))
        out += [sse("message_delta", {"type": "message_delta", "delta": {"stop_reason": stop, "stop_sequence": None},
                                      "usage": {"output_tokens": usage_out}}),
                sse("message_stop", {"type": "message_stop"})]
        self.wfile.write(b"".join(out))
        self.close_connection = True


if __name__ == "__main__":
    ThreadingHTTPServer(("", 8080), Handler).serve_forever()
