# Preset "uv": uv on Python 3.13 (the default interpreter) plus every
# supported (not end-of-life) CPython, installed through uv. Spliced in as
# the agent template's base stage (functions/environment.sh).
FROM ghcr.io/astral-sh/uv:python3.13-bookworm-slim

# A project's requires-python / .python-version / `uv run --python X` then
# resolves offline: the SIF is read-only at run time, so uv could not install
# one on demand. Managed installs live outside $HOME (never mounted), the
# version-named symlinks (python3.10 ... python3.14) go on PATH after the base
# interpreter, and downloads stay off so a missing version fails with uv's own
# error instead of a read-only-filesystem one.
ENV UV_PYTHON_INSTALL_DIR=/opt/uv-python UV_PYTHON_BIN_DIR=/opt/uv-python-bin
RUN uv python install 3.10 3.11 3.12 3.13 3.14 \
    && chmod -R a+rX /opt/uv-python /opt/uv-python-bin
ENV PATH="${PATH}:/opt/uv-python-bin" UV_PYTHON_DOWNLOADS=never
