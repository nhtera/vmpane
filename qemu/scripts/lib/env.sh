# Sourced by the QEMU pipeline scripts: paths, deps.lock access, and a build environment that sees only
# the pinned Xcode, the tools built from deps.lock and the sysroot (never Homebrew or /usr/local).
#
# Every runtime component is configured with the fixed prefix from deps.lock (/vmpane/qemu) and installed
# into $STAGE with DESTDIR, so the build directory never ends up inside a binary: a build in another
# checkout, or by another user (the CI runner), produces the same bytes.

QEMU_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
REPO_DIR=$(dirname "$QEMU_DIR")
LOCK=$QEMU_DIR/deps.lock
BUILD=${VMPANE_QEMU_BUILD:-$QEMU_DIR/build}
# Shared by clean builds (tarballs are verified on every use).
DOWNLOADS=${VMPANE_QEMU_DOWNLOADS:-$QEMU_DIR/build/downloads}
SRC=$BUILD/src
TOOLS=$BUILD/tools
STAGE=$BUILD/stage
STAMPS=$BUILD/stamps
LOGS=$BUILD/logs
PREFIX=$(jq -r .prefix "$LOCK")
SYSROOT=$STAGE$PREFIX
# Where build paths are mapped to in debug info and __FILE__ strings.
MAPPED_BUILD=/vmpane/build

die() {
    echo "error: $*" >&2
    exit 1
}

# lock_get <component> <field>
lock_get() {
    jq -er --arg n "$1" --arg f "$2" '.components[] | select(.name == $n) | .[$f]' "$LOCK" ||
        die "deps.lock: no $2 for $1"
}

lock_names() {  # lock_names [role]
    jq -r --arg r "${1:-}" '.components[] | select($r == "" or .role == $r) | .name' "$LOCK"
}

# fetch_entry <json with name, version, url, sha256>: the file in $DOWNLOADS, downloaded if missing; a
# SHA-256 mismatch is fatal. VMPANE_QEMU_MIRROR (a base URL holding the same file names) is tried first.
fetch_entry() {
    local name version url sha ext file
    name=$(jq -r .name <<<"$1")
    version=$(jq -r .version <<<"$1")
    url=$(jq -r .url <<<"$1")
    sha=$(jq -r .sha256 <<<"$1")
    ext=$(basename "$url" | grep -oE '\.tar\.(gz|xz|bz2)$|\.[a-z0-9]+$') || die "$name: no file extension: $url"
    file=$DOWNLOADS/$name-$version$ext
    mkdir -p "$DOWNLOADS"
    if [[ ! -f $file ]]; then
        local partial=$file.partial
        rm -f "$partial"
        { [[ -n ${VMPANE_QEMU_MIRROR:-} ]] && curl -fsSL --retry 3 -o "$partial" "$VMPANE_QEMU_MIRROR/$(basename "$file")"; } ||
            curl -fsSL --retry 3 -o "$partial" "$url" || die "$name: download failed: $url"
        mv "$partial" "$file"
    fi
    if [[ $(shasum -a 256 "$file" | cut -d' ' -f1) != "$sha" ]]; then
        rm -f "$file"
        die "$name: SHA-256 mismatch (file removed): $url"
    fi
    echo "$file"
}

# fetch <component>: its tarball (see fetch_entry).
fetch() {
    fetch_entry "$(jq -c --arg n "$1" '.components[] | select(.name == $n)' "$LOCK")"
}

# fetch_firmware <key>: a downloadable firmware input (buildImage, dbx).
fetch_firmware() {
    fetch_entry "$(jq -c --arg k "$1" '.firmware[$k]' "$LOCK")"
}

# Fresh source tree of <component> in $SRC/<component>, with its patches applied.
unpack() {
    local name=$1 tarball dir patch
    tarball=$(fetch "$name")
    dir=$SRC/$name
    rm -rf "$dir"
    mkdir -p "$dir"
    tar -xf "$tarball" -C "$dir" --strip-components=1
    for patch in $(jq -r --arg n "$name" '.components[] | select(.name == $n) | .patches[]' "$LOCK"); do
        patch -d "$dir" -p1 --batch --quiet --no-backup-if-mismatch <"$QEMU_DIR/patches/$name/$patch" ||
            die "$name: patch failed: $patch"
    done
    echo "$dir"
}

# Pinned Xcode (.xcode-version); a different one gives different binaries.
check_xcode() {
    local want have
    want=$(tr -d '[:space:]' <"$REPO_DIR/.xcode-version")
    have=$(xcodebuild -version | awk 'NR == 1 {print $2}')
    if [[ $have != "$want" ]]; then
        [[ ${VMPANE_ALLOW_XCODE_MISMATCH:-} == 1 ]] || die "Xcode $have is active, deps.lock builds use $want (.xcode-version)"
        echo "warning: Xcode $have instead of $want; binaries will not match CI" >&2
    fi
}

# The hermetic environment. Call once, after the tool stage exists (or while building it).
hermetic_env() {
    local cc
    cc=$(xcrun --sdk macosx -f clang)
    unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH OBJC_INCLUDE_PATH LIBRARY_PATH PKG_CONFIG_PATH ACLOCAL_PATH \
        DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH PYTHONPATH PYTHONHOME CFLAGS CXXFLAGS OBJCFLAGS CPPFLAGS LDFLAGS \
        MAKEFLAGS GNUMAKEFLAGS PERL5LIB HOMEBREW_PREFIX
    export PATH="$TOOLS/bin:$TOOLS/venv/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    export LC_ALL=C TZ=UTC
    export SDKROOT
    SDKROOT=$(xcrun --sdk macosx --show-sdk-path)
    export MACOSX_DEPLOYMENT_TARGET
    MACOSX_DEPLOYMENT_TARGET=$(jq -r .macosDeploymentTarget "$LOCK")
    export SOURCE_DATE_EPOCH
    SOURCE_DATE_EPOCH=$(jq -r .sourceDateEpoch "$LOCK")
    export ZERO_AR_DATE=1
    # clang through lib/cc, which drops run paths into the build directory.
    export VMPANE_CLANG=$cc VMPANE_BUILD_ROOT=$BUILD
    # (meson reads OBJC; QEMU takes OBJCC through --objcc.)
    export CC=$QEMU_DIR/scripts/lib/cc CXX=$QEMU_DIR/scripts/lib/c++ OBJC=$QEMU_DIR/scripts/lib/cc OBJCC=$QEMU_DIR/scripts/lib/cc
    # Version scripts (spice-gtk's git-version-gen) must not find the VMPane checkout around the sources and
    # report "-dirty".
    export GIT_CEILING_DIRECTORIES=$BUILD
    # pkg-config (a --define-prefix wrapper) sees only the sysroot.
    export PKG_CONFIG=$TOOLS/bin/pkg-config
    export PKG_CONFIG_LIBDIR=$SYSROOT/lib/pkgconfig:$SYSROOT/share/pkgconfig
    # GNU libtool is installed as glibtool (plain libtool is Apple's).
    export LIBTOOLIZE=glibtoolize
    COMMON_CFLAGS="-O2 -arch arm64 -ffile-prefix-map=$BUILD=$MAPPED_BUILD -Wdate-time"
    COMMON_LDFLAGS="-arch arm64 -Wl,-reproducible -Wl,-headerpad_max_install_names"
    JOBS=$(sysctl -n hw.ncpu)
    case ":$PATH:" in *:/opt/homebrew/* | *:/usr/local/*) die "PATH still reaches Homebrew: $PATH" ;; esac
}

# 16 hex digits naming a bundle build: every committed input of the QEMU pipeline and the pinned Xcode
# (docs, licence texts and the expected manifest itself do not change the output).
inputs_hash() {
    (
        cd "$REPO_DIR"
        git ls-files qemu .xcode-version Config/Entitlements/qemu.entitlements |
            grep -v -E '^qemu/(bundle-manifest\.json|LICENSES/.*|.*\.md)$' | LC_ALL=C sort | xargs shasum -a 256
    ) | shasum -a 256 | cut -c1-16
}
