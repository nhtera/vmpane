#!/usr/bin/env bash
# Downloads the QEMU bundle CI built for the current inputs (artifact qemu-bundle-<inputs hash> of the
# "QEMU bundle" workflow, qemu-deps.yml, on main) instead of building it, and installs it as
# build/qemu-bundle only if:
#   - the artifact comes from that workflow, run on main by a push or a manual dispatch;
#   - its build-provenance attestation verifies against this repository and that workflow (public
#     repositories; a private repository has no attestations, which is said, not skipped silently);
#   - every file matches qemu/bundle-manifest.json (qemu/scripts/check-bundle.sh).
# Anything else is refused; build the bundle locally then (qemu/BUILDING.md).
# Usage: scripts/fetch-qemu-bundle.sh [<inputs hash>]     (default: the hash of the checked-out inputs)
set -euo pipefail
cd "$(dirname "$0")/.."
source qemu/scripts/lib/env.sh

hash=${1:-$(inputs_hash)}
name=qemu-bundle-$hash
repo=$(gh repo view --json nameWithOwner -q .nameWithOwner)
workflow=.github/workflows/qemu-deps.yml

artifact=$(gh api "repos/$repo/actions/artifacts?name=$name&per_page=20" \
    --jq '[.artifacts[] | select(.expired | not)] | sort_by(.created_at) | last // empty | "\(.id) \(.workflow_run.id)"')
[[ -n $artifact ]] || die "no artifact $name (CI has not built these inputs, or it expired); build locally"
read -r id run <<<"$artifact"
origin=$(gh api "repos/$repo/actions/runs/$run" --jq '"\(.path) \(.head_branch) \(.event) \(.conclusion)"')
case $origin in
    "$workflow main push success" | "$workflow main workflow_dispatch success") ;;
    *) die "artifact $name comes from an untrusted run ($origin); refusing it" ;;
esac

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
gh api "repos/$repo/actions/artifacts/$id/zip" >"$work/artifact.zip"
unzip -q "$work/artifact.zip" -d "$work"
archive=$work/$name.tar.zst
[[ -f $archive ]] || die "artifact $name does not hold $name.tar.zst"

if [[ $(gh repo view "$repo" --json visibility -q .visibility) == PUBLIC ]]; then
    gh attestation verify "$archive" --repo "$repo" --signer-workflow "$repo/$workflow" >/dev/null ||
        die "the attestation of $name does not verify; refusing it"
    echo "fetch-qemu-bundle: attestation verified ($repo, $workflow)"
else
    echo "fetch-qemu-bundle: $repo is private, so there is no attestation; relying on qemu/bundle-manifest.json"
fi

mkdir -p "$work/x"
tar --zstd -xf "$archive" -C "$work/x"
qemu/scripts/check-bundle.sh "$work/x/qemu-bundle"
rm -rf build/qemu-bundle
mkdir -p build
mv "$work/x/qemu-bundle" build/qemu-bundle
echo "fetch-qemu-bundle: installed build/qemu-bundle ($name)"
