#!/bin/bash
# update.sh - run by DirectAdmin plugin manager on plugin update.
# Re-applies permissions and sudoers (same as fresh install, keeps data).
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "${DIR}/.." && pwd)"
if [ -f "${PLUGIN_DIR}/scripts/install.sh" ]; then
    bash "${PLUGIN_DIR}/scripts/install.sh"
else
    bash "${DIR}/install.sh"
fi
