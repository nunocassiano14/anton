#!/bin/bash

set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(cd "${SCRIPT_DIRECTORY}/.." && pwd)"
SOURCE_APP="${PROJECT_DIRECTORY}/build/Anton.app"
INSTALL_DIRECTORY="${HOME}/Applications"
DESTINATION_APP="${INSTALL_DIRECTORY}/Anton.app"

"${SCRIPT_DIRECTORY}/build-app.sh"
/bin/mkdir -p "${INSTALL_DIRECTORY}"
/usr/bin/ditto "${SOURCE_APP}" "${DESTINATION_APP}"
/usr/bin/codesign --verify --deep --strict "${DESTINATION_APP}"

LAUNCH_LABEL="com.augustalabs.anton.overlay"
LAUNCH_DOMAIN="gui/$(/usr/bin/id -u)"
if /bin/launchctl print "${LAUNCH_DOMAIN}/${LAUNCH_LABEL}" >/dev/null 2>&1; then
    /bin/launchctl bootout "${LAUNCH_DOMAIN}/${LAUNCH_LABEL}"
fi
/usr/bin/open -n "${DESTINATION_APP}"

echo "Installed ${DESTINATION_APP}"
