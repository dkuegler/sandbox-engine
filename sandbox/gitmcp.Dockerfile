# Git MCP sidecar: the only container with a git binary, exposing a fixed
# read-only tool set over MCP (streamable HTTP, bearer-token
# authenticated). The server is stdlib-only, so nothing beyond git and
# python3 is installed here.
#
# Built by build_images() in functions/environment.sh, which
# assembles a throwaway context directory holding this file (as
# "Dockerfile") plus git-mcp-server.py. apptainer's dockerfile:/buildkit:
# bootstrap takes a context DIRECTORY and always reads "Dockerfile" from
# it, so this file cannot be passed to `apptainer build` directly.
FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends git python3 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY git-mcp-server.py /usr/local/bin/git-mcp-server.py
RUN chmod +x /usr/local/bin/git-mcp-server.py

ENTRYPOINT ["/usr/local/bin/git-mcp-server.py"]
