#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/jev-window-fixture.XXXXXX")"
swiftc scripts/window-fixture.swift -o "$FIXTURE_DIR/JevWindowFixture"
exec "$FIXTURE_DIR/JevWindowFixture"
