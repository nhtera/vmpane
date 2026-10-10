#!/usr/bin/env bash
# All linters; exits non-zero on any finding.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/env.sh

swift_paths=(App VMHelper CLI UITests Packages/VMPaneKit/Sources Packages/VMPaneKit/Tests Packages/VMPaneKit/Package.swift
    Packages/VMPaneSpice/Sources/VMPaneSpice Packages/VMPaneSpice/Package.swift)

echo "== swiftlint"
# --strict: lint fails on any finding, warnings included.
swiftlint lint --strict --quiet
echo "== swift-format"
swift format lint --strict -r "${swift_paths[@]}"
echo "== rustfmt + clippy"
(cd agent && cargo fmt --all --check && cargo clippy --workspace --all-targets -- -D warnings)
echo "== workflows"
scripts/check-workflows.rb
echo "lint: ok"
