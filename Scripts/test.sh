#!/bin/bash

set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(cd "${SCRIPT_DIRECTORY}/.." && pwd)"

cd "${PROJECT_DIRECTORY}"
/usr/bin/swift run anton-self-test

if [[ -d "/Applications/Xcode.app" ]]; then
    DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" \
        /usr/bin/xcrun swift test --enable-swift-testing
else
    echo "Full Xcode is not installed; the equivalent standalone suite above is authoritative."
fi
