# Preset "sdaps": the latex preset (full TeX Live plus uv) and SDAPS
# (https://sdaps.org), for designing questionnaires and processing scanned
# surveys. Spliced in as the agent template's base stage
# (functions/environment.sh).
FROM texlive/texlive:latest-full
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

# Built from source below, having no Linux wheels: SDAPS's C extension,
# pycairo and PyGObject (compiler, headers, gettext for SDAPS's translations).
# At run time SDAPS calls zbarimg (code128/qr IDs) and file (`add`), and loads
# Poppler, Pango and GLib through GObject introspection (PDF import with
# `add --convert`, `annotate`, `boxgallery`). GTK is left out: `sdaps gui`
# needs a display, and none reaches the sandbox.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates xz-utils gcc libc6-dev pkgconf gettext \
        libcairo2-dev libtiff-dev libglib2.0-dev libgirepository-2.0-dev \
        gir1.2-poppler-0.18 gir1.2-pango-1.0 zbar-tools file \
    && rm -rf /var/lib/apt/lists/*

# SDAPS's own venv, /opt/sdaps, on a uv-managed CPython 3.13, carrying every
# optional dependency: reportlab and Pillow (`report reportlab`), OpenCV
# (`add --convert`), pandas and pyarrow (`export feather`). The uv variables
# stay inside this RUN, so uv in the session behaves as in the latex preset.
# Bytecode is compiled now: the image is read-only at run time.
RUN export UV_PYTHON_INSTALL_DIR=/opt/uv-python UV_NO_CACHE=1 \
    && uv python install --no-bin 3.13 \
    && uv venv --managed-python --python 3.13 /opt/sdaps \
    && uv pip install --python /opt/sdaps/bin/python --compile-bytecode \
        pycairo PyGObject reportlab pillow opencv-python-headless pandas pyarrow

# SDAPS itself: the release tarball, pinned by checksum, built with meson from
# a throwaway venv. Its meson.build finds pycairo through pkg-config, and a
# pycairo installed from PyPI ships no py3cairo.pc, so one is written for the
# build. The LaTeX class comes from TeX Live: its sdaps package (1.9.10) is
# the class this release bundles, so -Dlatex stays off. /usr/local/bin/sdaps
# runs the venv's interpreter, whatever python3 is first on PATH. Upstream's
# end-to-end test (setup tex, stamp, add --convert, recognize, report) then
# runs against that installed command; its log is printed only on failure.
RUN set -eu; \
    src=/tmp/sdaps-build; \
    mkdir "$src"; \
    cd "$src"; \
    curl -fsSLo sdaps.tar.xz https://github.com/sdaps/sdaps/releases/download/v1.9.13/sdaps-1.9.13.tar.xz; \
    echo 'bbdb37d92a75e87e845d0e99ea7bdcb46d629168f8595324d2750e76fb59b4c6  sdaps.tar.xz' | sha256sum -c -; \
    tar -xJf sdaps.tar.xz; \
    UV_NO_CACHE=1 uv venv --python /opt/sdaps/bin/python tools; \
    UV_NO_CACHE=1 uv pip install --python tools/bin/python meson ninja; \
    mkdir pc; \
    /opt/sdaps/bin/python -c 'import cairo; print("Name: py3cairo", "Description: Python 3 bindings for cairo", "Version: " + cairo.version, "Requires: cairo", "Cflags: -I" + cairo.get_include(), sep="\n")' >pc/py3cairo.pc; \
    export PATH="$src/tools/bin:$PATH" PKG_CONFIG_PATH="$src/pc"; \
    meson setup --prefix=/opt/sdaps --buildtype=release build sdaps-1.9.13; \
    meson install -C build; \
    sed -i '1s|^#!.*|#!/opt/sdaps/bin/python|' /opt/sdaps/bin/sdaps; \
    ln -s /opt/sdaps/bin/sdaps /usr/local/bin/sdaps; \
    chmod -R a+rX /opt/uv-python /opt/sdaps; \
    mkdir test; \
    cd test; \
    sh ../sdaps-1.9.13/test/run-test.sh /usr/local/bin/sdaps >../test.log 2>&1 \
        || { cat ../test.log; exit 1; }; \
    rm -rf "$src"
