#!/usr/bin/env python3
"""Minimal MCP (2025-11-25) server exposing a fixed set of read-only git
tools against a single repository. Runs in the git-mcp sidecar container;
the agent container only ever sees a read-only bind mount of .git.

Transport: a Unix domain socket (path given by --socket), one JSON-RPC
message per line (UTF-8 JSON followed by "\\n"), matching the framing of
the MCP stdio transport
(https://modelcontextprotocol.io/specification/2025-11-25/basic/transports).
A request gets exactly one reply line; a notification (no "id") gets none.

This used to be streamable-HTTP on loopback TCP, bearer-token
authenticated. That put the server on the *host's* network namespace
(apptainer instances share it unless run with --net, which needs root),
so every local process could reach it and the token was the only
barrier. A Unix socket removes the network exposure entirely: the
socket file is created mode 0600 inside a 0700 run directory owned by
the invoking user, so the kernel's own connect()-time permission check
is the access control, and the agent's forwarder (`nc -U`) reaches it
only because that run directory is bind-mounted into both the sidecar
and the agent container. No token, no Origin header, nothing to leak
via /proc/<pid>/cmdline or environ.

initialize, notifications/initialized, ping, tools/list, tools/call.

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
import json
import os
import re
import socketserver
import subprocess
import sys

PROTOCOL_VERSION = "2025-11-25"

# Cap on a single JSON-RPC message (one line); the agent is untrusted and
# the server is a plain socketserver-based Unix stream server.
MAX_MESSAGE_BYTES = 1 << 20

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
#
# Command-scope config (GIT_CONFIG_COUNT/GIT_CONFIG_KEY_<n>/
# GIT_CONFIG_VALUE_<n>) is git's highest-precedence *protected* scope, so
# these neutralise the equivalent keys in the mounted global config
# (--gitconfig below) rather than being overridden by it.
#
# credential.helper and core.sshCommand are deliberately NOT neutralised
# here: they are the reason to mount the host config at all -- they are
# what lets git_ls_remote reach a private remote -- and git's own trust
# model treats the user's global config as trusted (git-config(5),
# "Protected configuration").
_GIT_CONFIG_OVERRIDES = {
    # git_status would otherwise run this command against an
    # agent-controlled worktree.
    "core.fsmonitor": "false",
    # Nothing here should open an editor.
    "core.editor": "false",
    # Empty, not "false": prevents a credential prompt from hanging the
    # 30s subprocess timeout.
    "core.askpass": "",
    # No signing path is exposed.
    "gpg.program": "false",
    # Not serving fetches; a hook here would be pure attack surface.
    "uploadpack.packObjectsHook": "",
}
_GIT_ENV = {
    "PATH": "/usr/bin:/bin",
    "HOME": "/nonexistent",
    # The repository is bind-mounted read-only into this container; keep
    # git from trying to refresh/lock the index.
    "GIT_OPTIONAL_LOCKS": "0",
    "GIT_TERMINAL_PROMPT": "0",
    "GIT_CONFIG_NOSYSTEM": "1",
    # Overridden by main() to the --gitconfig path when the host has a
    # global config bind-mounted in; /dev/null otherwise (no identity).
    "GIT_CONFIG_GLOBAL": "/dev/null",
    # ext:: is already "never" by default; be explicit rather than rely on
    # the default staying that way.
    "GIT_ALLOW_PROTOCOL": "http:https:ssh:git",
    "GIT_CONFIG_COUNT": str(len(_GIT_CONFIG_OVERRIDES)),
}
for _i, (_k, _v) in enumerate(_GIT_CONFIG_OVERRIDES.items()):
    _GIT_ENV[f"GIT_CONFIG_KEY_{_i}"] = _k
    _GIT_ENV[f"GIT_CONFIG_VALUE_{_i}"] = _v
del _i, _k, _v


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


class ThreadingUnixServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True
    allow_reuse_address = True


class Handler(socketserver.StreamRequestHandler):
    """One TCP-like connection per client, framed as newline-delimited
    JSON-RPC -- the same framing the MCP stdio transport uses. The agent
    never talks to this directly; it spawns `nc -U <socket>` as its MCP
    "command" and nc simply relays stdin/stdout to this connection.
    """

    def _write(self, obj):
        self.wfile.write(json.dumps(obj).encode("utf-8") + b"\n")
        self.wfile.flush()

    def _error(self, msg_id, code, message):
        self._write({"jsonrpc": "2.0", "id": msg_id, "error": {"code": code, "message": message}})

    def handle(self):
        while True:
            try:
                line = self.rfile.readline(MAX_MESSAGE_BYTES + 1)
            except (ConnectionError, OSError):
                return
            if not line:
                return  # client closed the connection
            if len(line) > MAX_MESSAGE_BYTES:
                sys.stderr.write("git-mcp-server: message exceeds %d bytes, closing connection\n" % MAX_MESSAGE_BYTES)
                return
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                self._error(None, -32700, "parse error")
                continue
            if not isinstance(msg, dict):
                self._error(None, -32600, "invalid request")
                continue
            self._dispatch(msg)

    def _dispatch(self, msg):
        method = msg.get("method")
        msg_id = msg.get("id")

        if method == "initialize":
            result = {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "git-mcp-sidecar", "version": "1.0.0"},
            }
            self._write({"jsonrpc": "2.0", "id": msg_id, "result": result})
            return

        if method == "notifications/initialized":
            return  # notification: no reply

        if method == "ping":
            self._write({"jsonrpc": "2.0", "id": msg_id, "result": {}})
            return

        if method == "tools/list":
            tools = [
                {"name": t["name"], "description": t["description"], "inputSchema": t["inputSchema"]}
                for t in TOOLS
            ]
            self._write({"jsonrpc": "2.0", "id": msg_id, "result": {"tools": tools}})
            return

        if method == "tools/call":
            self._tools_call(msg_id, msg.get("params") or {})
            return

        if "id" in msg:
            self._error(msg_id, -32601, f"method not found: {method}")
        # else: unknown notification, silently dropped per JSON-RPC.

    def _tool_error(self, msg_id, text):
        self._write(
            {
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": {"content": [{"type": "text", "text": text}], "isError": True},
            }
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
        self._write(
            {
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": {"content": [{"type": "text", "text": out}], "isError": rc != 0},
            }
        )


def _apply_gitconfig(gitconfig_path):
    """When the host's global git config was bind-mounted in (--gitconfig),
    point git at it; otherwise _GIT_ENV's default (/dev/null) stands,
    keeping the sidecar with no identity -- unchanged from before this
    option existed.
    """
    if gitconfig_path:
        _GIT_ENV["GIT_CONFIG_GLOBAL"] = gitconfig_path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", required=True)
    parser.add_argument("--socket", required=True, help="Unix domain socket path to listen on")
    parser.add_argument(
        "--gitconfig",
        default=None,
        help="path to a read-only bind-mounted host git global config (omitted when the host has none)",
    )
    args = parser.parse_args()

    _apply_gitconfig(args.gitconfig)

    # A worktree/submodule checkout has .git as a FILE, not a directory.
    if not os.path.exists(os.path.join(args.repository, ".git")):
        print(f"error: {args.repository} is not a git repository (no .git)", file=sys.stderr)
        sys.exit(1)

    # A stale socket file (e.g. a prior crashed run reusing the path) makes
    # bind() fail with "address already in use"; this run owns the path
    # (it lives under a fresh per-run RUN_DIR), so clearing it first is safe.
    try:
        os.unlink(args.socket)
    except FileNotFoundError:
        pass

    server = ThreadingUnixServer(args.socket, Handler)
    # Belt-and-braces alongside the 0700 run directory: only the owning
    # user (or root) can open() this path, which is the entire access
    # control model now that there is no bearer token.
    os.chmod(args.socket, 0o600)
    server.repository = args.repository
    print(f"git-mcp-server: serving {args.repository} on unix:{args.socket}", file=sys.stderr)
    server.serve_forever()


if __name__ == "__main__":
    main()
