#!/bin/bash
# user_suspend_post.sh - NOLOGIN all login roles of suspended DA user.
PLUGIN_DIR="/usr/local/directadmin/plugins/postgres_manager"
HELPER="${PLUGIN_DIR}/scripts/pg_helper.sh"
[ -x "$HELPER" ] || exit 0
[ -n "${username:-}" ] || exit 0
if id postgres >/dev/null 2>&1; then
    sudo -n -u postgres "$HELPER" suspend --user "$username" >/dev/null 2>&1 || true
fi
exit 0
