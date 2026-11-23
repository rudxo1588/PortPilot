#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
if [[ ! -x Build/PortPilot.app/Contents/MacOS/PortPilot ]]; then
    ./build.sh
fi
open Build/PortPilot.app
