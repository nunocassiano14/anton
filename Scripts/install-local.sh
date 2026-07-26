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

echo "Installed ${DESTINATION_APP}"
