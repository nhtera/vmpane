#!/usr/bin/env bash
# Downloads an agent MSI into build/guest-tools/windows-extra/, where guest-tools/build-iso.sh
# (VMPANE_GUEST_TOOLS_EXTRA) and the Windows golden build pick it up:
#   guest-tools/fetch-agent-msi.sh [run-id]          the CI job's (default: the newest successful run on main)
#   guest-tools/fetch-agent-msi.sh --release vX.Y.Z  agent-release.yml's for that tag, checked against its
#                                                    build-provenance attestation (the MSI is not Authenticode-signed)
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
out="$root/build/guest-tools/windows-extra"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
if [[ ${1:-} == --release ]]; then
    tag=${2:?usage: fetch-agent-msi.sh --release vX.Y.Z}
    run=$(gh run list --workflow agent-release.yml --branch "$tag" --status success --limit 1 --json databaseId --jq '.[0].databaseId')
    [[ -n $run ]] || { echo "fetch-agent-msi: no successful agent-release run for $tag" >&2; exit 1; }
    gh run download "$run" --name agent-windows-arm64 --dir "$tmp"
else
    run=${1:-$(gh run list --branch main --workflow CI --status success --limit 1 --json databaseId --jq '.[0].databaseId')}
    [[ -n $run ]] || { echo "fetch-agent-msi: no successful CI run on main" >&2; exit 1; }
    gh run download "$run" --name vmpane-agent-windows-arm64 --dir "$tmp"
fi
msi=$(find "$tmp" -name 'vmpane-agent.msi' | head -1)
[[ -n $msi ]] || { echo "fetch-agent-msi: run $run has no MSI" >&2; exit 1; }
if [[ -n ${tag:-} ]]; then
    gh attestation verify "$msi" --repo nhtera/vmpane --source-ref "refs/tags/$tag" \
        --signer-workflow nhtera/vmpane/.github/workflows/agent-release.yml >/dev/null \
        || { echo "fetch-agent-msi: the MSI of run $run has no valid attestation for $tag" >&2; exit 1; }
fi
mkdir -p "$out"
cp "$msi" "$out/vmpane-agent.msi"
echo "$out/vmpane-agent.msi (CI run $run)"
