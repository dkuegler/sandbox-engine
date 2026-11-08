# Preset "sdaps": the latex preset (full TeX Live plus uv) and SDAPS
# (https://sdaps.org), for designing questionnaires and processing scanned
# surveys. Spliced in as the agent template's base stage
# (functions/environment.sh).
FROM texlive/texlive:latest-full
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

# Built from source below, having no Linux wheels: SDAPS's C extension,
# pycairo and PyGObject (compiler, headers, gettext for SDAPS's translations,
# patch for the NumPy 2 fix).
# At run time SDAPS calls zbarimg (code128/qr IDs) and file (`add`), and loads
# Poppler, Pango and GLib through GObject introspection (PDF import with
# `add --convert`, `annotate`, `boxgallery`). GTK is left out: `sdaps gui`
# needs a display, and none reaches the sandbox.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates xz-utils gcc libc6-dev pkgconf gettext patch \
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

# NumPy 2.0 removed np.float_ and np.unicode_, which sdaps/pandas/buddies.py
# uses, so `sdaps export feather` fails with an AttributeError (1.9.13 is the
# latest release; upstream master still has both names). The diff swaps in
# np.float64 and np.str_, the types those aliases name in NumPy 1.x, so it
# changes nothing there. It is a heredoc because the build context,
# sandbox/agent/ (functions/environment.sh), does not reach this directory;
# that needs a BuildKit builder, which the legacy one (docker build with
# DOCKER_BUILDKIT=0) is not. It is applied with --fuzz=0: a tarball it no
# longer matches fails the build instead of shipping unpatched.
COPY <<'EOF' /tmp/sdaps-build/numpy2-compat.diff
diff --git a/sdaps/pandas/buddies.py b/sdaps/pandas/buddies.py
index 53c95e2..171ba34 100644
--- a/sdaps/pandas/buddies.py
+++ b/sdaps/pandas/buddies.py
@@ -137,7 +137,7 @@ class Box(model.buddy.Buddy, metaclass=model.buddy.Register):
         self._qualities = []
 
         return [(self.obj.id_csv(), np.int_, self._values),
-                (self.obj.id_csv() + '_quality', np.float_, self._qualities)]
+                (self.obj.id_csv() + '_quality', np.float64, self._qualities)]
 
     def append_row(self):
         self._values.append(self.obj.data.state)
@@ -154,7 +154,7 @@ class Textbox(Box, metaclass=model.buddy.Register):
         self._texts = []
 
         return [(self.obj.id_csv(), np.bool_, self._states),
-                (self.obj.id_csv() + '_text', np.unicode_, self._texts),]
+                (self.obj.id_csv() + '_text', np.str_, self._texts),]
 
     def append_row(self):
         self._states.append(self.obj.data.state)
EOF

# SDAPS itself: the release tarball, pinned by checksum and patched as above
# (the COPY made $src), built with meson from a throwaway venv. Its
# meson.build finds pycairo through pkg-config, and a pycairo installed from
# PyPI ships no py3cairo.pc, so one is written for the build. The LaTeX class
# comes from TeX Live: its sdaps package (1.9.10) is the class this release
# bundles, so -Dlatex stays off. /usr/local/bin/sdaps runs the venv's
# interpreter, whatever python3 is first on PATH. Upstream's end-to-end test
# (setup tex, stamp, add --convert, recognize, report) then runs against that
# installed command; its log is printed only on failure.
RUN set -eu; \
    src=/tmp/sdaps-build; \
    cd "$src"; \
    curl -fsSLo sdaps.tar.xz https://github.com/sdaps/sdaps/releases/download/v1.9.13/sdaps-1.9.13.tar.xz; \
    echo 'bbdb37d92a75e87e845d0e99ea7bdcb46d629168f8595324d2750e76fb59b4c6  sdaps.tar.xz' | sha256sum -c -; \
    tar -xJf sdaps.tar.xz; \
    patch -d sdaps-1.9.13 -p1 --forward --fuzz=0 --no-backup-if-mismatch <numpy2-compat.diff; \
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
