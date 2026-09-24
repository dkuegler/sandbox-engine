# Preset "shell": the uv preset's base (Python 3.13, fixed) plus shellcheck
# and the interpreters for its dialects: dash and ksh (bash is in the base).
# Spliced in as the agent template's base stage (functions/environment.sh).
FROM ghcr.io/astral-sh/uv:python3.13-bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends shellcheck dash ksh \
    && rm -rf /var/lib/apt/lists/*

# Shells shellcheck has no dialect for get a stub that says so and exits
# 127, instead of "command not found" or running an unchecked script
# (docs/usage.md).
RUN for s in zsh fish tcsh csh; do \
        msg="$s: not installed in this sandbox -- the shell preset only ships the interpreters shellcheck itself supports (sh/dash, bash, ksh); $s is outside that capability boundary. See sandbox/shell/Dockerfile."; \
        printf '#!/bin/sh\necho '"'"'%s'"'"' >&2\nexit 127\n' "$msg" > "/usr/local/bin/$s"; \
        chmod +x "/usr/local/bin/$s"; \
    done
