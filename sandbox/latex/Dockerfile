# Full TeX Live install (pdflatex, gs, poppler-utils, imagemagick) plus
# uv, for projects that need both a LaTeX toolchain and `uv run`/`uv sync`
# against a pyproject.toml/.venv inside the sandbox.
#
# uv is installed by copying its binaries out of Astral's official
# distroless uv image, the method documented at
# https://docs.astral.sh/uv/guides/integration/docker/ — no curl/install
# script, no extra apt dependency.
#
# Select it via a project's sandbox.yml (environment.preset: latex, or
# environment.dockerfile: sandbox/latex/Dockerfile for a fork of this
# file), or via a --environment preset=latex / dockerfile=<path>
# command-line flag. Either way sandbox.sh splices this file's last stage
# in as the shared template's "base" stage, so it never needs to know
# about claude/opencode/omp itself; resolve_environment
# (functions/environment.sh) points CUSTOM_DOCKERFILE at this file
# directly for the "latex" preset case, the same bundled/trusted
# dockerfile-splice pattern as the "shell" preset (see
# sandbox/shell/Dockerfile).
FROM texlive/texlive:latest-full
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/
