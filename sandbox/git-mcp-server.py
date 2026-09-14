#!/usr/bin/env python3
"""Minimal MCP (2025-11-25, streamable HTTP) server exposing a fixed set of
read-only git tools against a single repository. Runs in the git-mcp sidecar
container; the agent container only ever sees a read-only bind mount of .git.

Protocol surface implemented (see
https://modelcontextprotocol.io/specification/2025-11-25/basic/transports
and .../basic/lifecycle and .../server/tools):
  - POST /mcp: JSON-RPC request/notification. Requests get a single JSON
    object response (Content-Type: application/json); notifications and
    responses get a bare 202.
  - initialize, notifications/initialized, ping, tools/list, tools/call.

Auth: every request must carry "Authorization: Bearer <GIT_MCP_TOKEN>".
GIT_MCP_TOKEN is mandatory -- the server refuses to start without it.
Per the transport spec a request carrying an Origin header that is not a
loopback origin is rejected with 403 (DNS-rebinding defence).

Mutating git operations (add/commit/reset/checkout/branch-create) are
intentionally NOT exposed as tools in this server (v1).

SECURITY MODEL OF THE TOOL LAYER
--------------------------------
The MCP client is the untrusted agent. Every string it supplies is an
*operand*, never an option: values are validated by `_operand` /`_ref` /
`_path` / `_remote_name` below (which reject a leading "-" outright) and
the resulting argv additionally carries `--end-of-options` so git itself
stops option parsing before the operand. Without this, arguments such as
`--output=<file>` (git-diff/git-show write their output to that file) or
`--upload-pack=<exec>` (git-ls-remote) turn a "read-only" tool into an
arbitrary-file-write or command-execution primitive.
"""
import argparse
import hmac
import json
import os
import re
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

PROTOCOL_VERSION = "2025-11-25"

# Cap on a single JSON-RPC body; the agent is untrusted and the server is
# a plain ThreadingHTTPServer.
MAX_BODY_BYTES = 1 << 20

# --- operand validation ----------------------------------------------

_REF_RE = re.compile(r"\A[A-Za-z0-9][A-Za-z0-9._/@{}^~:-]*\Z")
_REMOTE_NAME_RE = re.compile(r"\A[A-Za-z0-9][A-Za-z0-9._-]*\Z")
MAX_OPERAND_LEN = 512


def _operand(name, value):
    """Common checks for every agent-supplied argv element."""
    if not isinstance(value, str):
        raise ValueError(f"{name}: expected a string, got {type(value).__name__}")
    if not value:
        raise ValueError(f"{name}: must not be empty")
    if len(value) > MAX_OPERAND_LEN:
        raise ValueError(f"{name}: too long (max {MAX_OPERAND_LEN})")
    if value.startswith("-"):
        raise ValueError(f"{name}: must not start with '-' (options are not accepted)")
    if "\x00" in value or "\n" in value:
        raise ValueError(f"{name}: must not contain NUL or newline")
    return value


def _ref(args, key, required=True, default=None):
    if key not in args or args[key] is None:
        if required:
            raise ValueError(f"missing required argument: {key}")
        return default
    value = _operand(key, args[key])
    if not _REF_RE.match(value):
        raise ValueError(f"{key}: not a valid git revision/ref name")
    return value


def _path(args, key, required=True):
    if key not in args or args[key] is None:
        if required:
            raise ValueError(f"missing required argument: {key}")
        return None
    value = _operand(key, args[key])
    if value.startswith("/"):
        raise ValueError(f"{key}: must be relative to the repository root")
    if ".." in value.split("/"):
        raise ValueError(f"{key}: must not traverse outside the repository")
    return value


def _max_count(args):
    value = args.get("max_count", 20)
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError("max_count: expected an integer")
    if not 1 <= value <= 1000:
        raise ValueError("max_count: must be between 1 and 1000")
    return value


def _remote_name(repo, args):
    """Only an already-configured remote NAME is accepted.

    An arbitrary URL here would let the agent reach the network from the
    sidecar (SSRF / credential probing) and, for transports that run a
    helper, execute code. Names are additionally checked against the
    repository's configured remotes so unknown names cannot be
    reinterpreted as a path or URL by git.
    """
    value = args.get("remote", "origin")
    _operand("remote", value)
    if not _REMOTE_NAME_RE.match(value):
        raise ValueError("remote: must be a configured remote name, not a URL or path")
    known, rc = _git(repo, ["remote"])
    if rc != 0:
        raise ValueError("unable to enumerate configured remotes")
    names = known.split()
    if value not in names:
        raise ValueError(f"remote: unknown remote {value!r} (configured: {', '.join(names) or 'none'})")
    return value


# --- tool definitions -------------------------------------------------
#
# Each "argv" callable receives (repo, arguments) and returns the argv
# tail appended to ["/usr/bin/git", "-C", repo]. Every element it places
# there is either a constant chosen here or a validated operand.

TOOLS = [
    {
        "name": "git_status",
        "description": "Show the working tree status.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
        "argv": lambda repo, a: ["status"],
    },
    {
        "name": "git_log",
        "description": "Show commit logs. Optional 'max_count' and 'path'.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "max_count": {"type": "integer", "description": "limit number of commits (1-1000)"},
                "path": {"type": "string", "description": "restrict to a path, relative to the repo root"},
            },
            "additionalProperties": False,
        },
        "argv": lambda repo, a: ["log", f"-n{_max_count(a)}", "--end-of-options"]
        + (["--", _path(a, "path")] if a.get("path") is not None else []),
    },
    {
        "name": "git_diff",
        "description": "Show changes. Optional 'target' (ref or ref..ref) and 'path'.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "target": {"type": "string", "description": "ref or ref..ref"},
                "path": {"type": "string", "description": "relative to the repo root"},
            },
            "additionalProperties": False,
        },
        "argv": lambda repo, a: ["diff", "--end-of-options"]
        + ([_ref(a, "target", required=False)] if a.get("target") is not None else [])
        + (["--", _path(a, "path")] if a.get("path") is not None else []),
    },
    {
        "name": "git_show",
        "description": "Show a commit or object. Required 'ref'.",
        "inputSchema": {
            "type": "object",
            "properties": {"ref": {"type": "string"}},
            "required": ["ref"],
            "additionalProperties": False,
        },
        "argv": lambda repo, a: ["show", "--end-of-options", _ref(a, "ref")],
    },
    {
        "name": "git_blame",
        "description": "Show what revision/author last modified each line of a file. Required 'path'.",
        "inputSchema": {
            "type": "object",
            "properties": {"path": {"type": "string"}},
            "required": ["path"],
            "additionalProperties": False,
        },
        "argv": lambda repo, a: ["blame", "--end-of-options", "--", _path(a, "path")],
    },
    {
        "name": "git_branch",
        "description": "List branches (read-only).",
        "inputSchema": {
            "type": "object",
            "properties": {"all": {"type": "boolean", "description": "include remotes"}},
            "additionalProperties": False,
        },
        "argv": lambda repo, a: ["branch", "--list"] + (["-a"] if a.get("all") else []),
    },
    {
        "name": "git_ls_remote",
        "description": "List references in a configured remote (defaults to origin).",
        "inputSchema": {
            "type": "object",
            "properties": {"remote": {"type": "string", "description": "configured remote NAME (not a URL)"}},
            "additionalProperties": False,
        },
        "argv": lambda repo, a: ["ls-remote", "--end-of-options", _remote_name(repo, a)],
    },
]
TOOLS_BY_NAME = {t["name"]: t for t in TOOLS}

# Belt-and-braces: nothing validated above can produce a leading "-" past
# the constants chosen in this file, so any such element is a bug here.
_GIT_ENV = {
    "PATH": "/usr/bin:/bin",
    "HOME": "/nonexistent",
    # The repository is bind-mounted read-only into this container; keep
    # git from trying to refresh/lock the index.
    "GIT_OPTIONAL_LOCKS": "0",
    "GIT_TERMINAL_PROMPT": "0",
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_GLOBAL": "/dev/null",
    # ext:: is already "never" by default; be explicit rather than rely on
    # the default staying that way.
    "GIT_ALLOW_PROTOCOL": "http:https:ssh:git",
}


def _git(repo, argv):
    for a in argv:
        if not isinstance(a, str):
            raise ValueError("internal error: non-string argv element")
    proc = subprocess.run(
        ["/usr/bin/git", "-C", repo] + argv,
        capture_output=True,
        text=True,
        timeout=30,
        env=_GIT_ENV,
        cwd=repo,
    )
    out = proc.stdout
    if proc.returncode != 0:
        out += "\n" + proc.stderr
    return out, proc.returncode


class Handler(BaseHTTPRequestHandler):
    server_version = "git-mcp/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _send_json(self, code, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_no_content(self, code=202):
        self.send_response(code)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _authorized(self):
        # server.token is guaranteed non-empty by main().
        return hmac.compare_digest(
            self.headers.get("Authorization", ""), f"Bearer {self.server.token}"
        )

    def _origin_ok(self):
        """Reject a present-but-non-loopback Origin (transport spec)."""
        origin = self.headers.get("Origin")
        if origin is None:
            return True
        if origin == "null":
            return False
        host = urlparse(origin).hostname
        return host in ("127.0.0.1", "::1", "localhost")

    def _preflight(self):
        """Shared path checks. Returns True when the request may proceed."""
        if self.path.split("?", 1)[0].rstrip("/") != "/mcp":
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return False
        if not self._origin_ok():
            self._send_json(403, {"error": "forbidden origin"})
            return False
        if not self._authorized():
            self._send_json(403, {"error": "unauthorized"})
            return False
        return True

    def do_GET(self):
        if not self._preflight():
            return
        # No server-initiated SSE stream in this minimal implementation.
        self.send_response(405)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_POST(self):
        if not self._preflight():
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self._send_json(400, {"error": "bad Content-Length"})
            return
        if length < 0 or length > MAX_BODY_BYTES:
            self._send_json(413, {"error": "request body too large"})
            return
        raw = self.rfile.read(length) if length else b""
        try:
            msg = json.loads(raw or b"{}")
        except json.JSONDecodeError:
            self._send_json(400, {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "parse error"}})
            return
        if not isinstance(msg, dict):
            self._send_json(400, {"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "invalid request"}})
            return

        method = msg.get("method")
        msg_id = msg.get("id")

        if method == "initialize":
            result = {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "git-mcp-sidecar", "version": "1.0.0"},
            }
            self._send_json(200, {"jsonrpc": "2.0", "id": msg_id, "result": result})
            return

        if method == "notifications/initialized":
            self._send_no_content()
            return

        if method == "ping":
            self._send_json(200, {"jsonrpc": "2.0", "id": msg_id, "result": {}})
            return

        if method == "tools/list":
            tools = [
                {"name": t["name"], "description": t["description"], "inputSchema": t["inputSchema"]}
                for t in TOOLS
            ]
            self._send_json(200, {"jsonrpc": "2.0", "id": msg_id, "result": {"tools": tools}})
            return

        if method == "tools/call":
            self._tools_call(msg_id, msg.get("params") or {})
            return

        if "id" in msg:
            self._send_json(
                200,
                {"jsonrpc": "2.0", "id": msg_id, "error": {"code": -32601, "message": f"method not found: {method}"}},
            )
        else:
            self._send_no_content()

    def _tool_error(self, msg_id, text):
        self._send_json(
            200,
            {
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": {"content": [{"type": "text", "text": text}], "isError": True},
            },
        )

    def _tools_call(self, msg_id, params):
        name = params.get("name")
        args = params.get("arguments")
        if args is None:
            args = {}
        if not isinstance(args, dict):
            self._tool_error(msg_id, "arguments must be an object")
            return
        tool = TOOLS_BY_NAME.get(name)
        if tool is None:
            self._tool_error(msg_id, f"unknown tool: {name}")
            return
        allowed = set(tool["inputSchema"].get("properties", {}))
        unknown = sorted(set(args) - allowed)
        if unknown:
            self._tool_error(msg_id, f"unknown argument(s): {', '.join(unknown)}")
            return
        try:
            argv = tool["argv"](self.server.repository, args)
            out, rc = _git(self.server.repository, argv)
        except ValueError as exc:
            self._tool_error(msg_id, str(exc))
            return
        except subprocess.TimeoutExpired:
            self._tool_error(msg_id, "git timed out after 30s")
            return
        except Exception as exc:  # noqa: BLE001
            sys.stderr.write(f"git-mcp-server: internal error in {name}: {exc!r}\n")
            self._tool_error(msg_id, "internal error")
            return
        self._send_json(
            200,
            {
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": {"content": [{"type": "text", "text": out}], "isError": rc != 0},
            },
        )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", required=True)
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--host", default="127.0.0.1")
    args = parser.parse_args()

    # A worktree/submodule checkout has .git as a FILE, not a directory.
    if not os.path.exists(os.path.join(args.repository, ".git")):
        print(f"error: {args.repository} is not a git repository (no .git)", file=sys.stderr)
        sys.exit(1)

    token = os.environ.get("GIT_MCP_TOKEN", "")
    if len(token) < 16:
        print(
            "error: GIT_MCP_TOKEN must be set to at least 16 characters; refusing to serve unauthenticated",
            file=sys.stderr,
        )
        sys.exit(1)

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.repository = args.repository
    server.token = token
    print(f"git-mcp-server: serving {args.repository} on http://{args.host}:{args.port}/mcp", file=sys.stderr)
    server.serve_forever()


if __name__ == "__main__":
    main()
