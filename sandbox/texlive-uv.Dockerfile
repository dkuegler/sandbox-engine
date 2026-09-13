# Sample custom base: a full TeX Live install (pdflatex, gs, poppler-utils,
# imagemagick) plus uv, for projects that need both a LaTeX toolchain and
# `uv run`/`uv sync` against a pyproject.toml/.venv inside the sandbox.
#
# uv is installed by copying its binaries out of Astral's official
# distroless uv image, the method documented at
# https://docs.astral.sh/uv/guides/integration/docker/ — no curl/install
# script, no extra apt dependency.
#
# Select it via a project's sandbox.yml (environment.dockerfile: <path to
# this file>), or via a --environment dockerfile=<path> command-line flag.
# sandbox.sh splices this file's last stage in as the shared template's
# "base" stage, so it never needs to know about claude/opencode/omp itself.
FROM texlive/texlive:latest-full
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/
