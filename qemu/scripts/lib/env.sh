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

# The tarball of <component> in $DOWNLOADS, downloaded if missing; a SHA-256 mismatch is fatal.
# VMPANE_QEMU_MIRROR (a base URL holding the same file names) is tried before upstream.
fetch() {
    local name=$1 url sha file ext
    url=$(lock_get "$name" url)
    sha=$(lock_get "$name" sha256)
    ext=$(basename "$url" | grep -oE '\.tar\.(gz|xz|bz2)$') || die "$name: unknown archive type: $url"
    file=$DOWNLOADS/$name-$(lock_get "$name" version)$ext
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
    export CC=$cc CXX=${cc}++ OBJC=$cc
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
