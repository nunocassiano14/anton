#!/bin/bash

set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(cd "${SCRIPT_DIRECTORY}/.." && pwd)"
BUILD_CONFIGURATION="${CONFIGURATION:-release}"

case "${BUILD_CONFIGURATION}" in
    Debug|debug)
        SWIFT_CONFIGURATION="debug"
        ;;
    Release|release)
        SWIFT_CONFIGURATION="release"
        ;;
    *)
        echo "Unsupported build configuration: ${BUILD_CONFIGURATION}" >&2
        exit 2
        ;;
esac

cd "${PROJECT_DIRECTORY}"
/usr/bin/swift build -c "${SWIFT_CONFIGURATION}" --product Anton
/usr/bin/swift build -c "${SWIFT_CONFIGURATION}" --product anton-hook

BIN_DIRECTORY="$(/usr/bin/swift build -c "${SWIFT_CONFIGURATION}" --show-bin-path)"
APP_DIRECTORY="${PROJECT_DIRECTORY}/build/Anton.app"
EXPECTED_APP_DIRECTORY="${PROJECT_DIRECTORY}/build/Anton.app"

if [[ "${APP_DIRECTORY}" != "${EXPECTED_APP_DIRECTORY}" || "${APP_DIRECTORY}" != */build/Anton.app ]]; then
    echo "Refusing to clean an unexpected app path: ${APP_DIRECTORY}" >&2
    exit 3
fi

/bin/rm -rf "${APP_DIRECTORY}"
/bin/mkdir -p \
    "${APP_DIRECTORY}/Contents/MacOS" \
    "${APP_DIRECTORY}/Contents/Helpers" \
    "${APP_DIRECTORY}/Contents/Resources"

/usr/bin/ditto "${BIN_DIRECTORY}/Anton" "${APP_DIRECTORY}/Contents/MacOS/Anton"
/usr/bin/ditto "${BIN_DIRECTORY}/anton-hook" "${APP_DIRECTORY}/Contents/Helpers/anton-hook"
/usr/bin/ditto "${PROJECT_DIRECTORY}/Resources/Info.plist" "${APP_DIRECTORY}/Contents/Info.plist"
/bin/chmod 755 \
    "${APP_DIRECTORY}/Contents/MacOS/Anton" \
    "${APP_DIRECTORY}/Contents/Helpers/anton-hook"

/usr/bin/codesign \
    --force \
    --deep \
    --sign - \
    --entitlements "${PROJECT_DIRECTORY}/Resources/Gilfoyle.entitlements" \
    "${APP_DIRECTORY}"

/usr/bin/codesign --verify --deep --strict "${APP_DIRECTORY}"
/usr/bin/plutil -lint "${APP_DIRECTORY}/Contents/Info.plist"

echo "${APP_DIRECTORY}"
