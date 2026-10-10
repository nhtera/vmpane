#!/usr/bin/env bash
# Lays out the QEMU bundle from the sysroot (qemu/scripts/build-deps.sh):
#   bin/         qemu-system-aarch64, qemu-img, swtpm, swtpm_setup      → VMPane.app/Contents/Helpers/qemu/bin
#   lib/         the libraries they load                                → VMPane.app/Contents/Helpers/qemu/lib
#   share/       firmware (edk2-aarch64-code.fd, edk2-aarch64-vars-sb.fd; unpadded) and QEMU data in
#                share/qemu (passed with -L)                            → VMPane.app/Contents/Resources/qemu/share
#   frameworks/  SPICE client libraries for the helper app (CocoaSpice) → VMPaneVM.app/Contents/Frameworks
#   MANIFEST.json  versions, and the SHA-256 of every file before signing (files) and as shipped (signed)
# Load paths become relative: programs load @rpath/<lib> with an @executable_path/../lib run path, libraries
# load each other with @loader_path/<lib>, and every library's id is @rpath/<lib>. Mach-Os are stripped of
# local symbols, hashed, then signed ad hoc (QEMU with its entitlements) so the bundle runs as is;
# scripts/sign.sh --qemu-only re-signs it for release.
#
# Usage: qemu/scripts/package.sh [--out <dir>] [--no-firmware]     (default: build/qemu-bundle)
#   --no-firmware  skip the firmware (build-edk2.sh uses this bundle to run its build VM)
set -euo pipefail
source "$(dirname "$0")/lib/env.sh"

out=$REPO_DIR/build/qemu-bundle
firmware=true
while (($#)); do
    case $1 in
        --out) out=${2:?--out needs a directory}; shift 2 ;;
        --no-firmware) firmware=false; shift ;;
        *) die "usage: package.sh [--out <dir>] [--no-firmware]" ;;
    esac
done
[[ -x $SYSROOT/bin/qemu-system-aarch64 ]] || die "no QEMU in $SYSROOT; run qemu/scripts/build-deps.sh"
firmware_files=(edk2-aarch64-code.fd edk2-aarch64-vars-sb.fd)
if $firmware; then
    for f in "${firmware_files[@]}"; do
        [[ -f $BUILD/firmware/$f ]] || die "no $BUILD/firmware/$f; run qemu/scripts/build-edk2.sh and make-vars.sh"
    done
fi
export LC_ALL=C

programs=(qemu-system-aarch64 qemu-img swtpm swtpm_setup)
client_roots=(libspice-client-glib-2.0.8.dylib)
# QEMU data the virt board uses: the virtio-net option ROM (QEMU installs ROMs for every architecture).
qemu_data=(efi-virtio.rom)

# The sysroot file a load command refers to, or nothing for system libraries.
resolve() {
    case $1 in
        "$PREFIX"/lib/*) echo "$SYSROOT/lib/${1#"$PREFIX"/lib/}" ;;
        @rpath/*) find "$SYSROOT/lib" -maxdepth 2 -name "${1#@rpath/}" | head -1 ;;
    esac
}

deps() { otool -L "$1" | tail -n +2 | awk '{print $1}'; }

# copy_closure <dest dir> <file...>: the files and every sysroot library they load, by install-name leaf.
copy_closure() {
    local dest=$1 queue=("${@:2}") f dep src leaf
    mkdir -p "$dest"
    while ((${#queue[@]})); do
        f=${queue[0]}
        queue=("${queue[@]:1}")
        for dep in $(deps "$f"); do
            src=$(resolve "$dep")
            [[ -n $src ]] || continue
            [[ -f $src ]] || die "${f##*/} loads $dep, which is not in the sysroot"
            leaf=$(basename "$dep")
            [[ -f $dest/$leaf ]] && continue
            cp -L "$src" "$dest/$leaf"
            chmod 644 "$dest/$leaf"
            queue+=("$dest/$leaf")
        done
    done
}

# relink <file> <loader>: rewrites sysroot load paths; <loader> is @rpath (programs) or @loader_path.
relink() {
    local f=$1 via=$2 dep args=()
    for dep in $(deps "$f"); do
        [[ -n $(resolve "$dep") ]] && args+=(-change "$dep" "$via/$(basename "$dep")")
    done
    if [[ $(file -b "$f") == *"shared library"* ]]; then
        args+=(-id "@rpath/$(basename "$f")")
    fi
    # (stderr: the "invalidates the code signature" warning; the signature is replaced later)
    ((${#args[@]} == 0)) || install_name_tool "${args[@]}" "$f" 2>/dev/null
}

rm -rf "$out"
mkdir -p "$out/bin" "$out/lib" "$out/share/qemu" "$out/frameworks"

for p in "${programs[@]}"; do
    cp "$SYSROOT/bin/$p" "$out/bin/$p"
    chmod 755 "$out/bin/$p"
done
copy_closure "$out/lib" "${programs[@]/#/$out/bin/}"
for root in "${client_roots[@]}"; do cp -L "$SYSROOT/lib/$root" "$out/frameworks/$root"; done
copy_closure "$out/frameworks" "${client_roots[@]/#/$out/frameworks/}"
for d in "${qemu_data[@]}"; do cp "$SYSROOT/share/qemu/$d" "$out/share/qemu/$d"; done
if $firmware; then
    for f in "${firmware_files[@]}"; do cp "$BUILD/firmware/$f" "$out/share/$f"; done
    chmod 644 "$out"/share/*.fd
fi

machos=()
while IFS= read -r -d '' f; do
    [[ $(file -b "$f") == *Mach-O* ]] && machos+=("$f")
done < <(find "$out" -type f -print0)
for f in "${machos[@]}"; do
    # Run paths from the build (cmake's install path, meson's path to sibling libraries) point outside
    # the bundle, and some hold the build directory.
    for rp in $(otool -l "$f" | awk '$1 == "cmd" && $2 == "LC_RPATH" {getline; getline; print $2}'); do
        install_name_tool -delete_rpath "$rp" "$f" 2>/dev/null
    done
    case $f in
        "$out"/bin/*)
            relink "$f" @rpath
            install_name_tool -add_rpath @executable_path/../lib "$f" 2>/dev/null
            ;;
        *) relink "$f" @loader_path ;;
    esac
    strip -x "$f" 2>/dev/null
    # The build's signature (ld signs ad hoc; QEMU's install adds its entitlement) is now invalid. Removing
    # it last: install_name_tool cannot edit a file whose signature was removed.
    codesign --remove-signature "$f"
done

# file<TAB>sha256 for every file of the bundle but MANIFEST.json.
hashes() {
    (
        cd "$out"
        find . -type f ! -name MANIFEST.json | sed 's|^\./||' | sort | while read -r f; do
            printf '%s\t%s\n' "$f" "$(shasum -a 256 "$f" | cut -d' ' -f1)"
        done
    ) | jq -R -s 'split("\n") | map(select(. != "") | split("\t") | {(.[0]): .[1]}) | add'
}

# Before signing: two builds of the same deps.lock must agree on every hash (the reproducibility check).
unsigned=$(hashes)

for f in "${machos[@]}"; do
    if [[ $f == "$out/bin/qemu-system-aarch64" ]]; then
        codesign --force --sign - --entitlements "$REPO_DIR/Config/Entitlements/qemu.entitlements" "$f"
    else
        codesign --force --sign - "$f"
    fi
done 2>/dev/null

# As shipped (ad hoc signatures carry no time or identity, so these are reproducible too): what
# fetch-qemu-bundle.sh checks a downloaded bundle against.
jq -n --arg lock "$(shasum -a 256 "$LOCK" | cut -d' ' -f1)" \
    --argjson c "$(jq -c '[.components[] | select(.role == "runtime") | {(.name): .version}] | add' "$LOCK")" \
    --argjson files "$unsigned" --argjson signed "$(hashes)" \
    '{lockSha256: $lock, components: $c, files: $files, signed: $signed}' >"$out/MANIFEST.json"

echo "package: $out ($(du -sh "$out" | cut -f1); QEMU side $(du -shc "$out/bin" "$out/lib" "$out/share" | tail -1 | cut -f1))"
