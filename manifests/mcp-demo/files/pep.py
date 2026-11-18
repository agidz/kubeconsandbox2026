"""Ask Keycloak for a decision on each MCP tool invocation."""

import base64
import json
import os
import ssl
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import Request, urlopen

REALM = os.environ["KEYCLOAK_REALM_URL"]
CLIENT = os.environ.get("PEP_CLIENT_ID", "mcp-tools")
SVID = Path(os.environ.get("SVID_FILE", "/svid/jwt_svid.token"))
RESOURCE_TYPE = os.environ.get("RESOURCE_TYPE", "mcp:tool")
TLS = ssl.create_default_context(cafile=os.environ.get("CA_FILE"))

token_lock = threading.Lock()
access_token = None
expires_at = 0


def log(**fields):
    timestamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    print(json.dumps({"ts": timestamp, **fields}), flush=True)


def post(path, data, headers):
    request = Request(REALM + path, data=data, headers=headers, method="POST")
    with urlopen(request, timeout=5, context=TLS) as response:
        return json.load(response)


def pep_token():
    global access_token, expires_at
    with token_lock:
        if access_token and time.time() + 30 < expires_at:
            return access_token
        fields = {
            "grant_type": "client_credentials",
            "client_id": CLIENT,
            "client_assertion_type": "urn:ietf:params:oauth:client-assertion-type:jwt-spiffe",
            "client_assertion": SVID.read_text().strip(),
        }
        response = post(
            "/protocol/openid-connect/token",
            urlencode(fields).encode(),
            {"Content-Type": "application/x-www-form-urlencoded"},
        )
        access_token = response["access_token"]
        expires_at = time.time() + response.get("expires_in", 60)
        return access_token


def claims(authorization):
    # Agent Router validates the token. This service uses the subject as policy input.
    scheme, _, token = authorization.partition(" ")
    if scheme.lower() != "bearer":
        raise ValueError("bearer credentials required")
    payload = token.split(".")[1]
    padded = payload + "=" * (-len(payload) % 4)
    return json.loads(base64.urlsafe_b64decode(padded))


def decide(subject, tool):
    question = {
        "subject": {"type": "user", "id": f"id:{subject}"},
        "resource": {"type": RESOURCE_TYPE, "id": tool},
        "action": {"name": "call"},
    }
    answer = post(
        "/authzen/access/v1/evaluation",
        json.dumps(question).encode(),
        {"Content-Type": "application/json", "Authorization": f"Bearer {pep_token()}"},
    )
    return bool(answer.get("decision"))


class Handler(BaseHTTPRequestHandler):
    def answer(self, status, error=""):
        body = b"" if status == 200 else json.dumps({"error": error}).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/healthz" and not SVID.exists():
            self.answer(503, "no SVID yet")
        else:
            self.answer(200)

    do_DELETE = do_GET

    def do_POST(self):
        try:
            size = int(self.headers.get("Content-Length") or 0)
            message = json.loads(self.rfile.read(size) or b"{}")
            if not isinstance(message, dict) or message.get("method") != "tools/call":
                self.answer(200)
                return
            name = str(message.get("params", {}).get("name", ""))
            tool = name.split("__")[-1]
            identity = claims(self.headers.get("Authorization", ""))
            allowed = decide(identity["sub"], tool)
            log(
                decision="allow" if allowed else "deny",
                tool=tool,
                user=identity.get("preferred_username"),
                agent=(identity.get("act") or {}).get("client_id"),
            )
        except Exception as error:
            log(decision="error", error=f"{type(error).__name__}: {error}")
            self.answer(403, "authorization unavailable")
            return

        if allowed:
            self.answer(200)
        else:
            self.answer(403, f"tool {tool} denied by policy")

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    log(msg=f"AuthZEN PEP on :{port}, PDP {REALM}")
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
