"""Forward delegated MCP calls through Agent Router.

The proxy authenticates as the configured Keycloak client with an SVID and
exchanges each caller token with consent. The incoming agent header is an
identity assertion from the RemoteMCPServer configuration, constrained by
NetworkPolicy. Agent Router verifies the exchanged token and enforces policy.
"""
import base64, hashlib, http.client, json, os, queue, re, secrets, ssl, threading, time, urllib.error, urllib.parse, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REALM = os.environ["KEYCLOAK_REALM_URL"]                 # https://keycloak.<domain>/realms/sandbox
CLIENT = os.environ.get("AGENT_CLIENT_ID", "mcp-agent")  # the Keycloak client this proxy acts as
UPSTREAM = urllib.parse.urlsplit(os.environ.get("UPSTREAM", "http://agent-router.envoy-gateway-system.svc.cluster.local/mcp"))
SVID = os.environ.get("SVID_FILE", "/svid/jwt_svid.token")
CTX = ssl.create_default_context(cafile=os.environ.get("CA_FILE"))
HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailer", "transfer-encoding",
       "upgrade", "host", "content-length", "authorization", "x-kagent-agent"}
_actor = {"value": None, "exp": 0}
_cache = {}            # sha256(user token) → (delegated token, exp)
_lock = threading.Lock()
OTLP = os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT", "")        # e.g. http://otel-collector.monitoring.svc:4318
SERVICE = os.environ.get("OTEL_SERVICE_NAME", "delegation-proxy")
_spans = queue.Queue(maxsize=1000)
_calls = {}            # (user, agent, tool, method, outcome) → count, cumulative since start
_pending = {}          # counted but not yet exported
_started_ns = time.time_ns()
_mlock = threading.Lock()


def count(user, agent, method, tool, status):
    outcome = ("allowed" if status < 400 else "denied" if status in (401, 403) else "error") if isinstance(status, int) else status
    key = (user, agent, tool or "", method or "", outcome)
    with _mlock:
        _pending[key] = _pending.get(key, 0) + 1


def _settle():
    """Move pending counts into the exported counters. A new series is first exported at 0 and gets its counts one
    export later, so Prometheus' increase() sees the step from 0 (it can't for a series whose first sample is 1)."""
    for key in list(_pending):
        if key in _calls:
            _calls[key] += _pending.pop(key)
        else:
            _calls[key] = 0
TRACEPARENT = re.compile(r"^00-([0-9a-f]{32})-([0-9a-f]{16})-([0-9a-f]{2})$")


def _attr(k, v):
    if isinstance(v, bool):
        return {"key": k, "value": {"boolValue": v}}
    if isinstance(v, int):
        return {"key": k, "value": {"intValue": str(v)}}
    return {"key": k, "value": {"stringValue": str(v)}}


def span(trace_id, span_id, parent_id, name, start_ns, end_ns, attrs, error=False):
    if not OTLP:
        return
    try:
        _spans.put_nowait({"traceId": trace_id, "spanId": span_id, "parentSpanId": parent_id or "", "name": name,
                           "kind": 2, "startTimeUnixNano": str(start_ns), "endTimeUnixNano": str(end_ns),
                           "attributes": [_attr(k, v) for k, v in attrs.items() if v is not None],
                           "status": {"code": 2 if error else 1}})
    except queue.Full:
        pass


def _post(path, payload):
    try:
        urllib.request.urlopen(urllib.request.Request(f"{OTLP}{path}", data=json.dumps(payload).encode(), method="POST",
                                                      headers={"Content-Type": "application/json"}), timeout=5).read()
        return True
    except OSError as e:
        log(msg=f"OTLP export to {path} failed", error=str(e))
        return False


def _exporter():
    """Every second: batch spans to the OTel Collector; every 15 s: the cumulative call counter. Telemetry is best
    effort and never blocks a call (spans are dropped if the collector is unreachable)."""
    resource = {"attributes": [_attr("service.name", SERVICE)]}
    scope = {"name": "kubeconsandbox.delegation-proxy"}
    last_metrics = 0
    while True:
        time.sleep(1)
        batch = []
        while not _spans.empty() and len(batch) < 200:
            batch.append(_spans.get_nowait())
        if batch:
            _post("/v1/traces", {"resourceSpans": [{"resource": resource, "scopeSpans": [{"scope": scope, "spans": batch}]}]})
        if time.time() - last_metrics >= 15:
            last_metrics = time.time()
            with _mlock:
                _settle()
                points = [{"attributes": [_attr("user.name", u), _attr("gen_ai.agent.name", a), _attr("gen_ai.tool.name", t),
                                          _attr("mcp.method.name", m), _attr("outcome", o)],
                           "startTimeUnixNano": str(_started_ns), "timeUnixNano": str(time.time_ns()), "asInt": str(n)}
                          for (u, a, t, m, o), n in _calls.items()]
            if points:
                _post("/v1/metrics", {"resourceMetrics": [{"resource": resource, "scopeMetrics": [{"scope": scope, "metrics": [
                    {"name": "delegation.proxy.calls", "unit": "{call}",
                     "description": "MCP calls an agent made for a user, by outcome (allowed, denied, error, refused_delegation)",
                     "sum": {"aggregationTemporality": 2, "isMonotonic": True, "dataPoints": points}}]}]}]})


def log(**kv):
    print(json.dumps({"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), **kv}), flush=True)


def claims(token):
    try:
        p = token.split(".")[1]
        return json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))
    except (IndexError, ValueError):
        return {}


class ExchangeError(Exception):
    pass


def token_call(parameters):
    """Authenticate the agent client with its SPIRE JWT-SVID."""
    with open(SVID, encoding="utf-8") as credential:
        assertion = credential.read().strip()
    fields = dict(parameters)
    fields.update(
        client_id=CLIENT,
        client_assertion=assertion,
        client_assertion_type="urn:ietf:params:oauth:client-assertion-type:jwt-spiffe",
    )
    request = urllib.request.Request(
        f"{REALM}/protocol/openid-connect/token",
        data=urllib.parse.urlencode(fields).encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=5, context=CTX) as response:
            return json.load(response)
    except urllib.error.HTTPError as response:
        try:
            details = json.load(response)
        except ValueError:
            raise ExchangeError(f"Keycloak answered {response.code}") from response
        reason = f"{details.get('error')}: {details.get('error_description', '')}"
        raise ExchangeError(reason.strip(": ")) from response


def actor_token():
    if _actor["value"] and _actor["exp"] > time.time() + 30:
        return _actor["value"]
    response = token_call({"grant_type": "client_credentials"})
    _actor["value"] = response["access_token"]
    _actor["exp"] = time.time() + response.get("expires_in", 60)
    return _actor["value"]


def delegated(user_token):
    """Cache the exchanged token by a hash of the user's incoming token."""
    fingerprint = hashlib.sha256(user_token.encode()).hexdigest()
    with _lock:
        cached = _cache.get(fingerprint)
        if cached and cached[1] > time.time() + 15:
            return cached[0], True

        access_type = "urn:ietf:params:oauth:token-type:access_token"
        response = token_call({
            "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
            "subject_token_type": access_type,
            "subject_token": user_token,
            "actor_token_type": access_type,
            "actor_token": actor_token(),
        })
        now = time.time()
        for key, (_, expiry) in list(_cache.items()):
            if expiry < now:
                del _cache[key]
        access_token = response["access_token"]
        _cache[fingerprint] = (access_token, now + response.get("expires_in", 60))
        return access_token, False


def mcp_summary(body):
    try:
        m = json.loads(body)
    except ValueError:
        return {}
    if not isinstance(m, dict):
        return {"kind": "batch" if isinstance(m, list) else "other"}
    if "method" not in m:   # a JSON-RPC response from the client (answer to a server request)
        return {"kind": "response", "keys": sorted(m)[:6]}
    out = {"method": m.get("method")}
    if m.get("method") == "tools/call":
        out["tool"] = (m.get("params") or {}).get("name")
    return out


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def deny(self, code, msg, **kv):
        log(status=code, error=msg, **kv)
        body = json.dumps({"jsonrpc": "2.0", "id": None, "error": {"code": -32001, "message": msg}}).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def handle_any(self):
        if self.path == "/healthz":   # ready once spiffe-helper has written the SVID
            ok = os.path.exists(SVID)
            self.send_response(200 if ok else 503)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        start = time.time_ns()
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        info = mcp_summary(body)
        m = TRACEPARENT.match(self.headers.get("traceparent", ""))
        trace_id, parent_id, flags = (m.group(1), m.group(2), m.group(3)) if m else (secrets.token_hex(16), None, "01")
        span_id = secrets.token_hex(8)
        agent = self.headers.get("x-kagent-agent", "")
        if agent != CLIENT:
            return self.deny(403, f"this proxy serves agent {CLIENT} only", agent=agent, **info)
        authz = self.headers.get("Authorization", "")
        if not authz.lower().startswith("bearer "):
            return self.deny(401, "no user token (kagent forwards the signed-in user's token)", agent=agent, **info)
        user = claims(authz[7:]).get("preferred_username", "?")
        try:
            token, cached = delegated(authz[7:])
        except ExchangeError as e:
            count(user, agent, info.get("method"), info.get("tool"), "refused_delegation")
            span(trace_id, span_id, parent_id, "delegate (refused by Keycloak)", start, time.time_ns(),
                 {"user.name": user, "gen_ai.agent.name": agent, "mcp.method.name": info.get("method"),
                  "error.type": "delegation_refused", "delegation.error": str(e)}, True)
            return self.deny(403, f"Keycloak refused the delegation: {e}", user=user, agent=agent, **info)
        except Exception as e:   # Keycloak unreachable, no SVID yet, ...
            return self.deny(503, f"delegation failed: {type(e).__name__}: {e}", user=user, agent=agent, **info)
        headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP}
        headers["Authorization"] = f"Bearer {token}"
        headers["traceparent"] = f"00-{trace_id}-{span_id}-{flags}"   # Agent Router's spans become children of ours
        act = claims(token).get("act", {}).get("client_id")
        attrs = {"user.name": user, "user.id": claims(token).get("sub"), "gen_ai.agent.name": agent,
                 "delegation.act.client_id": act, "mcp.method.name": info.get("method"),
                 "gen_ai.tool.name": info.get("tool"), "http.request.method": self.command, "token.cached": cached}
        name = f"delegate {info['method']}{' ' + info['tool'] if info.get('tool') else ''}" if info.get("method") else f"delegate {self.command}"
        conn = http.client.HTTPConnection(UPSTREAM.hostname, UPSTREAM.port or 80, timeout=300)
        try:
            conn.request(self.command, UPSTREAM.path + (f"?{urllib.parse.urlsplit(self.path).query}" if "?" in self.path else ""),
                         body=body or None, headers=headers)
            resp = conn.getresponse()
        except OSError as e:
            conn.close()
            span(trace_id, span_id, parent_id, name, start, time.time_ns(), {**attrs, "error.type": "upstream_unreachable"}, True)
            return self.deny(502, f"Agent Router unreachable: {e}", user=user, agent=agent, **info)
        detail = {}
        if resp.status >= 400:   # small error answers: log them (and still pass them on)
            err = resp.read(500)
            detail = {"upstream_error": err.decode(errors="replace")[:300], "request": body[:300].decode(errors="replace")}
        count(user, agent, info.get("method"), info.get("tool"), resp.status)
        log(status=resp.status, http=self.command, user=user, agent=agent, act=act,
            cached=cached, trace_id=trace_id, **info, **detail)
        # Stream the answer back (MCP may answer with server-sent events); the body ends when the connection closes.
        self.send_response(resp.status)
        for k, v in resp.getheaders():
            if k.lower() not in HOP:
                self.send_header(k, v)
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            if detail:
                self.wfile.write(err)
            while chunk := resp.read1(65536):
                self.wfile.write(chunk)
                self.wfile.flush()
        except (OSError, http.client.HTTPException, ValueError):   # either side closed mid-stream (SSE streams end so)
            pass
        finally:
            conn.close()
            self.close_connection = True
            span(trace_id, span_id, parent_id, name, start, time.time_ns(),
                 {**attrs, "http.response.status_code": resp.status, "error.type": str(resp.status) if resp.status >= 400 else None},
                 resp.status >= 400)

    do_GET = do_POST = do_DELETE = handle_any


if __name__ == "__main__":
    log(msg="delegation proxy", client=CLIENT, upstream=UPSTREAM.geturl(), otlp=OTLP or "off")
    threading.Thread(target=_exporter, daemon=True).start()
    ThreadingHTTPServer(("", 8080), Handler).serve_forever()
