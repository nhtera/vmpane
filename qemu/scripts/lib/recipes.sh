# Build recipes, one function per deps.lock component (recipe_<name>, dashes as underscores), sourced by
# build-deps.sh after lib/env.sh. A recipe runs in the hermetic environment with its log as stdout.
# Tools install into $TOOLS (build-only); runtime components install into $STAGE under the fixed prefix.

# --- Tools ------------------------------------------------------------------------------------------

recipe_python() {
    rm -rf "$TOOLS/python" "$TOOLS/venv"
    mkdir -p "$TOOLS/python"
    tar -xf "$(fetch python)" -C "$TOOLS/python" --strip-components=1
    "$TOOLS/python/bin/python3" -I -m venv "$TOOLS/venv"
    "$TOOLS/venv/bin/python3" -I -m pip install --quiet --disable-pip-version-check --no-cache-dir \
        --require-hashes --only-binary=:all: -r "$QEMU_DIR/tools-requirements.txt"
}

# configure && make && make install into $TOOLS.
tool_autotools() {
    local dir
    dir=$(unpack "$1")
    shift
    (cd "$dir" && ./configure --prefix="$TOOLS" --disable-dependency-tracking "$@" && make -j"$JOBS" && make install)
}

recipe_m4() { tool_autotools m4; }
recipe_autoconf() { tool_autotools autoconf; }
recipe_automake() { tool_autotools automake; }
# As glibtool/glibtoolize: plain `libtool` must stay Apple's (static archives).
recipe_libtool() { tool_autotools libtool --program-prefix=g; }

recipe_pkgconf() {
    tool_autotools pkgconf --with-pkg-config-dir= --with-system-libdir=/usr/lib \
        --with-system-includedir="$SDKROOT/usr/include"
    # Every .pc file has the fixed prefix; --define-prefix rewrites it to where the sysroot really is.
    rm -f "$TOOLS/bin/pkg-config"
    printf '#!/bin/sh\nexec "%s/bin/pkgconf" --define-prefix "$@"\n' "$TOOLS" >"$TOOLS/bin/pkg-config"
    chmod +x "$TOOLS/bin/pkg-config"
}

# --- Runtime components (installed into $STAGE under $PREFIX) ---------------------------------------

# Compiler and linker flags for the sysroot. The -I/-L paths are build-machine paths, but they only
# steer lookups; nothing records them in the output.
sysroot_flags() {
    export CFLAGS="$COMMON_CFLAGS -I$SYSROOT/include" CXXFLAGS="$COMMON_CFLAGS -I$SYSROOT/include"
    export CPPFLAGS="-I$SYSROOT/include" LDFLAGS="$COMMON_LDFLAGS -L$SYSROOT/lib"
}

# libtool archives carry the fixed prefix as a real path; pkg-config does that job instead.
drop_la_files() { find "$SYSROOT/lib" -name '*.la' -delete; }

# meson_component <name> [meson options...]: shared libraries only, no subproject downloads.
meson_component() {
    local name=$1 dir
    shift
    dir=$(unpack "$name")
    sysroot_flags
    meson setup "$dir/_build" "$dir" --prefix="$PREFIX" --libdir=lib --buildtype=plain --default-library=shared \
        --wrap-mode=nodownload -Dstrip=false "$@"
    meson compile -C "$dir/_build"
    meson install -C "$dir/_build" --destdir "$STAGE" --no-rebuild
}

# autotools_configure <name> [configure options...]: unpacks and configures into $COMPONENT_DIR, running
# autoreconf when the tarball has no configure script.
autotools_configure() {
    local name=$1
    shift
    COMPONENT_DIR=$(unpack "$name")
    sysroot_flags
    (
        cd "$COMPONENT_DIR"
        [[ -x configure ]] || autoreconf -fi
        ./configure --prefix="$PREFIX" --libdir="$PREFIX/lib" --disable-static --enable-shared \
            --disable-dependency-tracking "$@"
    )
}

# autotools_component <name> [configure options...]: configure, make, make install.
autotools_component() {
    autotools_configure "$@"
    make -C "$COMPONENT_DIR" -j"$JOBS"
    make -C "$COMPONENT_DIR" install DESTDIR="$STAGE"
    drop_la_files
}

recipe_libffi() { autotools_component libffi --disable-docs --disable-multi-os-directory; }

# 8-bit only (all glib uses); no JIT: the hardened runtime gives QEMU no allow-jit entitlement.
recipe_pcre2() {
    autotools_component pcre2 --enable-pcre2-8 --disable-pcre2-16 --disable-pcre2-32 --disable-jit \
        --disable-pcre2grep-libz --disable-pcre2grep-libbz2 --disable-pcre2test-libedit
}

# libintl that forwards to a real gettext if one is loaded and is a no-op otherwise (VMPane ships no
# translations of these libraries).
recipe_proxy_libintl() { meson_component proxy-libintl; }

recipe_glib() {
    meson_component glib -Dtests=false -Dinstalled_tests=false -Dintrospection=disabled -Dnls=disabled \
        -Dglib_debug=disabled -Dsysprof=disabled -Dman-pages=disabled -Ddocumentation=false -Dlibelf=disabled \
        -Ddtrace=disabled -Dsystemtap=disabled -Dselinux=disabled -Dlibmount=disabled
}

recipe_json_glib() {
    meson_component json-glib -Dintrospection=disabled -Ddocumentation=disabled -Dtests=false -Dman=false \
        -Dnls=disabled -Dconformance=false
}

recipe_pixman() { meson_component pixman -Dtests=disabled -Ddemos=disabled -Dgtk=disabled -Dlibpng=disabled; }

# libcrypto for libtpms/swtpm, libssl for spice-server. OpenSSL builds in-tree with relative paths and
# records its compiler command in the library, so it gets neither -ffile-prefix-map (that flag holds the
# build path) nor the lib/cc wrapper (its path is the checkout's); it adds no run paths anyway.
recipe_openssl() {
    local dir
    dir=$(unpack openssl)
    (
        cd "$dir"
        CC=$VMPANE_CLANG ./Configure darwin64-arm64-cc shared no-tests no-docs no-apps no-module no-legacy --prefix="$PREFIX" \
            --openssldir="$PREFIX/ssl" --libdir=lib -O2 -Wl,-reproducible -Wl,-headerpad_max_install_names
        make -j"$JOBS"
        make install_sw DESTDIR="$STAGE"
    )
}

recipe_libjpeg_turbo() {
    local dir
    dir=$(unpack libjpeg-turbo)
    sysroot_flags
    cmake -S "$dir" -B "$dir/_build" -G Ninja -DCMAKE_BUILD_TYPE=None -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_OSX_ARCHITECTURES=arm64 -DENABLE_STATIC=OFF -DWITH_TURBOJPEG=OFF \
        -DWITH_TOOLS=OFF -DWITH_TESTS=OFF
    cmake --build "$dir/_build"
    DESTDIR="$STAGE" cmake --install "$dir/_build"
}

recipe_libslirp() { meson_component libslirp; }

recipe_libusb() { autotools_component libusb --disable-examples-build --disable-tests-build; }

recipe_usbredir() { meson_component usbredir -Dtools=disabled -Dfuzzing=disabled -Dgit_werror=disabled; }

recipe_spice_protocol() { meson_component spice-protocol; }

recipe_spice_server() {
    meson_component spice-server -Dgstreamer=no -Dsasl=false -Dsmartcard=disabled -Dmanual=false -Dtests=false \
        -Dopus=disabled -Dlz4=false
}

# Core and base libraries only: spice-gtk needs them to link; no plugins are built or shipped. No
# pipeline-string parser (needs bison >= 2.4; nothing here builds pipelines from strings).
recipe_gstreamer() {
    meson_component gstreamer -Dauto_features=disabled -Dtests=disabled -Dexamples=disabled -Dbenchmarks=disabled \
        -Dtools=disabled -Ddoc=disabled -Dintrospection=disabled -Dnls=disabled -Dptp-helper=disabled \
        -Dgst_parse=false
}

recipe_gst_plugins_base() {
    meson_component gst-plugins-base -Dauto_features=disabled -Dtests=disabled -Dexamples=disabled \
        -Dtools=disabled -Ddoc=disabled -Dintrospection=disabled -Dnls=disabled -Dgl=disabled -Dorc=disabled
}

# spice-client-glib only (CocoaSpice draws; no GTK, USB redirection, webdav or smartcard in the client).
recipe_spice_gtk() {
    meson_component spice-gtk -Dgtk=disabled -Dwebdav=disabled -Dusbredir=disabled -Dlibcap-ng=disabled \
        -Dpolkit=disabled -Dsmartcard=disabled -Dsasl=disabled -Dintrospection=disabled -Dvapi=disabled -Degl=disabled \
        -Dgtk_doc=disabled -Dcoroutine=gthread -Dlz4=disabled -Dopus=disabled
}

recipe_libtpms() { autotools_component libtpms --with-openssl --with-tpm2; }

# Only the two programs VMPane runs: swtpm and swtpm_setup (swtpm_localca/swtpm_cert make certificates
# and need GMP and GnuTLS).
recipe_swtpm() {
    autotools_configure swtpm --with-openssl --without-gnutls --without-cuse --without-seccomp --disable-tests
    local dir
    for dir in src/utils src/swtpm src/swtpm_setup; do
        make -C "$COMPONENT_DIR/$dir" -j"$JOBS"
    done
    for dir in src/swtpm src/swtpm_setup; do
        make -C "$COMPONENT_DIR/$dir" install DESTDIR="$STAGE"
    done
    drop_la_files
}

# libfdt for the virt board's device tree (QEMU's own copy is a download-only subproject).
recipe_dtc() { meson_component dtc -Dtools=false -Dpython=disabled -Dtests=false -Dyaml=disabled -Dvalgrind=disabled; }

# qemu-system-aarch64 (HVF only: no TCG, so a VM can never fall back to emulation), qemu-img and the
# devices in qemu/configs/devices-vmpane.mak. SPICE for the display, slirp for user networking, libusb
# and usbredir for USB passthrough, CoreAudio for sound. Everything optional and unused is off.
recipe_qemu() {
    local dir
    dir=$(unpack qemu)
    sysroot_flags
    mkdir -p "$dir/_build"
    cp "$QEMU_DIR/configs/devices-vmpane.mak" "$dir/configs/devices/aarch64-softmmu/vmpane.mak"
    (
        cd "$dir/_build"
        ../configure --prefix="$PREFIX" --target-list=aarch64-softmmu --without-default-devices \
            --with-devices-aarch64=vmpane --objcc="$OBJCC" \
            --enable-hvf --disable-tcg --enable-fdt=system --enable-spice --enable-slirp --enable-libusb --enable-usb-redir --enable-tpm \
            --audio-drv-list=coreaudio --enable-tools --disable-download --disable-rust --disable-debug-info \
            --disable-docs --disable-sdl --disable-gtk --disable-cocoa --disable-vnc --disable-curses \
            --disable-dbus-display --disable-gnutls --disable-nettle --disable-gcrypt --disable-curl --disable-libssh \
            --disable-guest-agent --disable-user --disable-plugins --disable-png --disable-zstd --disable-capstone \
            --disable-snappy --disable-lzo --disable-bzip2 --disable-lzfse --disable-vde --disable-vmnet \
            --disable-libiscsi --disable-libnfs --disable-rbd --disable-brlapi \
            --extra-cflags="$CFLAGS" --extra-ldflags="$LDFLAGS"
        make -j"$JOBS"
        make install DESTDIR="$STAGE"
    )
}
