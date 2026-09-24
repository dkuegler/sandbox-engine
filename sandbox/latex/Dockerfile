# Preset "latex": full TeX Live plus uv. Spliced in as the agent template's
# base stage (functions/environment.sh); usable as a starting point for an
# environment.dockerfile.
# uv via COPY from Astral's image:
# https://docs.astral.sh/uv/guides/integration/docker/
FROM texlive/texlive:latest-full
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/
