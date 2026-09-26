#!/usr/bin/env python3
"""A protected MCP server and its OAuth 2.1 authorization server, on 127.0.0.1, for tests.

Prints its port on the first line of stdout, then serves until stdin closes:
  POST /mcp                                     the MCP server: 401 with resource_metadata
                                                without a valid bearer, else initialize and
                                                tools/list; 403 insufficient_scope for
                                                tools/call "create_issue" without issues:write
  GET  /.well-known/oauth-protected-resource/mcp   RFC 9728
  GET  /.well-known/oauth-authorization-server/auth RFC 8414
  POST /auth/register                           RFC 7591
  GET  /auth/authorize                          302 to the redirect with code and state
                                                (FAKE_OAUTH_DENY=1: error=access_denied)
  FAKE_OAUTH_SEED="<access> <refresh> <scope>"  a sign-in already done: both tokens valid
  POST /auth/token                              authorization_code with PKCE S256, and
                                                refresh_token (rotating; a used one is
                                                invalid_grant)
  GET  /log                                     every request as JSON, for assertions
No network beyond the loopback, stdlib only.
"""
import base64, hashlib, json, os, sys, threading, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE = {"clients": {}, "codes": {}, "access": {}, "refresh": {}, "log": [], "n": 0}
LOCK = threading.Lock()
DENY = os.environ.get("FAKE_OAUTH_DENY") == "1"
if os.environ.get("FAKE_OAUTH_SEED"):
    _access, _refresh, _scope = os.environ["FAKE_OAUTH_SEED"].split(" ", 2)
    STATE["access"][_access] = _scope
    STATE["refresh"][_refresh] = _scope


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    @property
    def base(self):
        return "http://127.0.0.1:%d" % self.server.server_address[1]

    def record(self, body=""):
        with LOCK:
            STATE["log"].append({"method": self.command, "path": self.path, "body": body,
                                 "authorization": self.headers.get("Authorization", "")})

    def send(self, status, body=None, headers=None, content_type="application/json"):
        data = b"" if body is None else (body if isinstance(body, bytes) else json.dumps(body).encode())
        self.send_response(status)
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        if body is not None:
            self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length).decode() if length else ""

    def do_GET(self):
        self.record()
        url = urllib.parse.urlparse(self.path)
        if url.path == "/.well-known/oauth-protected-resource/mcp":
            return self.send(200, {"resource": self.base + "/mcp", "authorization_servers": [self.base + "/auth"],
                                   "scopes_supported": ["read", "write"], "resource_name": "Fake MCP"})
        if url.path == "/.well-known/oauth-authorization-server/auth":
            return self.send(200, {"issuer": self.base + "/auth", "authorization_endpoint": self.base + "/auth/authorize",
                                   "token_endpoint": self.base + "/auth/token", "registration_endpoint": self.base + "/auth/register",
                                   "code_challenge_methods_supported": ["S256"], "response_types_supported": ["code"]})
        if url.path == "/auth/authorize":
            q = dict(urllib.parse.parse_qsl(url.query))
            client = STATE["clients"].get(q.get("client_id"))
            if not client or q.get("redirect_uri") not in client["redirect_uris"]:
                return self.send(400, {"error": "invalid_client"})
            if q.get("code_challenge_method") != "S256" or not q.get("code_challenge") or not q.get("resource"):
                return self.send(400, {"error": "invalid_request"})
            target = q["redirect_uri"] + "?"
            if DENY:
                target += urllib.parse.urlencode({"error": "access_denied", "error_description": "you chose Cancel",
                                                  "state": q.get("state", "")})
            else:
                with LOCK:
                    STATE["n"] += 1
                    code = "code-%d" % STATE["n"]
                    STATE["codes"][code] = {"challenge": q["code_challenge"], "redirect_uri": q["redirect_uri"],
                                            "resource": q["resource"], "scope": q.get("scope", ""), "client_id": q["client_id"]}
                target += urllib.parse.urlencode({"code": code, "state": q.get("state", "")})
            return self.send(302, headers={"Location": target})
        if url.path == "/log":
            with LOCK:
                return self.send(200, STATE["log"])
        self.send(404, {"error": "not_found"})

    def do_POST(self):
        raw = self.body()
        self.record(raw)
        url = urllib.parse.urlparse(self.path)
        if url.path == "/auth/register":
            meta = json.loads(raw or "{}")
            with LOCK:
                client_id = "client-%d" % (len(STATE["clients"]) + 1)
                STATE["clients"][client_id] = {"redirect_uris": meta.get("redirect_uris", [])}
            return self.send(201, {"client_id": client_id, "redirect_uris": meta.get("redirect_uris", []),
                                   "token_endpoint_auth_method": "none"})
        if url.path == "/auth/token":
            form = dict(urllib.parse.parse_qsl(raw))
            with LOCK:
                if form.get("grant_type") == "authorization_code":
                    grant = STATE["codes"].pop(form.get("code"), None)
                    verifier = form.get("code_verifier", "")
                    if (not grant or b64url(hashlib.sha256(verifier.encode()).digest()) != grant["challenge"]
                            or form.get("redirect_uri") != grant["redirect_uri"] or form.get("resource") != grant["resource"]):
                        return self.send(400, {"error": "invalid_grant"})
                    scope = grant["scope"]
                elif form.get("grant_type") == "refresh_token":
                    old = STATE["refresh"].pop(form.get("refresh_token"), None)
                    if old is None:
                        return self.send(400, {"error": "invalid_grant", "error_description": "refresh token is used up"})
                    scope = old
                else:
                    return self.send(400, {"error": "unsupported_grant_type"})
                STATE["n"] += 1
                access, refresh = "at-%d" % STATE["n"], "rt-%d" % STATE["n"]
                STATE["access"][access] = scope
                STATE["refresh"][refresh] = scope
            claims = b64url(json.dumps({"email": "baily@acme.dev"}).encode())
            return self.send(200, {"access_token": access, "token_type": "Bearer", "expires_in": 3600, "refresh_token": refresh,
                                   "scope": scope, "id_token": "e30." + claims + ".sig"})
        if url.path == "/mcp":
            auth = self.headers.get("Authorization", "")
            token = auth[7:] if auth.startswith("Bearer ") else ""
            with LOCK:
                scope = STATE["access"].get(token)
            if scope is None:
                return self.send(401, {"error": "unauthorized"}, headers={
                    "WWW-Authenticate": 'Bearer resource_metadata="%s/.well-known/oauth-protected-resource/mcp"' % self.base})
            message = json.loads(raw or "{}")
            method = message.get("method")
            if method == "initialize":
                return self.send(200, {"jsonrpc": "2.0", "id": message.get("id"), "result": {
                    "protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
                    "serverInfo": {"name": "fake", "title": "Fake MCP", "version": "1"}}})
            if method == "tools/call" and message.get("params", {}).get("name") == "create_issue" and "issues:write" not in scope.split():
                return self.send(403, {"error": "insufficient_scope"}, headers={
                    "WWW-Authenticate": 'Bearer error="insufficient_scope", scope="%s issues:write"' % scope})
            if method == "tools/call" and message.get("params", {}).get("name") == "list_issues":
                return self.send(200, {"jsonrpc": "2.0", "id": message.get("id"), "result": {
                    "content": [{"type": "text", "text": "ISSUE-1 The login page loops"}]}})
            if method == "tools/list":
                return self.send(200, {"jsonrpc": "2.0", "id": message.get("id"), "result": {"tools": [
                    {"name": "list_issues", "description": "Lists issues.", "inputSchema": {"type": "object"}},
                    {"name": "create_issue", "description": "Creates an issue.", "inputSchema": {"type": "object"}}]}})
            return self.send(202)
        self.send(404, {"error": "not_found"})


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    print(server.server_address[1], flush=True)
    sys.stdin.read()
    server.shutdown()


if __name__ == "__main__":
    main()
