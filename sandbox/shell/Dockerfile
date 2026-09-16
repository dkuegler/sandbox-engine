# Preset "shell": the "uv" preset's base image (see sandbox.example.yml's
# preset docs) plus shellcheck and the real shell interpreters shellcheck
# itself models (sh/dash, bash, ksh; bash is already present in the base
# Debian image). Other common shells (zsh, fish, tcsh, csh) are NOT
# installed as real interpreters -- shellcheck has no dialect for them, so
# this preset does not pretend to support them. Instead, each gets a thin
# stub binary on PATH that, if invoked, prints the capability boundary to
# stderr and exits nonzero, rather than either silently working (a script
# would run under an interpreter shellcheck never analyzed it against) or
# failing with an opaque "command not found".
#
# Selected via a project's sandbox.yml (environment.preset: shell) or a
# --environment preset=shell command-line flag. Unlike
# environment.dockerfile, this file is bundled with sandbox-engine itself
# (trusted), not supplied by the project being sandboxed: resolve_environment
# (functions/environment.sh) points CUSTOM_DOCKERFILE at this file directly
# for the shell preset, reusing the same "splice in as the shared
# template's base stage" dockerfile-mode machinery generate_dockerfile
# already has for environment.dockerfile (see sandbox/latex/Dockerfile for
# the same bundled/trusted preset pattern applied to a TeX Live base).
#
# Pinned to Python 3.13 (the "uv"/"python" presets' default
# python_version): dockerfile-mode base images are static text, not
# textually parameterized by environment.python_version the way those
# presets are.
#
# Shell selection: dash and ksh are the two of shellcheck's four supported
# dialects (sh/dash, bash, ksh, bats) not already guaranteed present in a
# minimal Debian image alongside bash; dash doubles as /bin/sh but is
# installed explicitly here so it's never implicit.
FROM ghcr.io/astral-sh/uv:python3.13-bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends shellcheck dash ksh \
    && rm -rf /var/lib/apt/lists/*

# Capability-boundary stubs: shells shellcheck does not model. Running one
# prints why it isn't a real interpreter here instead of "command not
# found" or silently executing under an untested dialect.
RUN for s in zsh fish tcsh csh; do \
        msg="$s: not installed in this sandbox -- the shell preset only ships the interpreters shellcheck itself supports (sh/dash, bash, ksh); $s is outside that capability boundary. See sandbox/shell/Dockerfile."; \
        printf '#!/bin/sh\necho '"'"'%s'"'"' >&2\nexit 127\n' "$msg" > "/usr/local/bin/$s"; \
        chmod +x "/usr/local/bin/$s"; \
    done
