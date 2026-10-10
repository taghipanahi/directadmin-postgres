#!/bin/bash
# user_create_post.sh - create owner role for new DA user. Runs as root.
# Env: username (+ user.conf contents)
PLUGIN_DIR="/usr/local/directadmin/plugins/postgres_manager"
HELPER="${PLUGIN_DIR}/scripts/pg_helper.sh"
[ -x "$HELPER" ] || exit 0
[ -n "${username:-}" ] || exit 0
if id postgres >/dev/null 2>&1; then
    sudo -n -u postgres "$HELPER" ensure-user --user "$username" >/dev/null 2>&1 || echo "postgres_manager: could not create owner role for $username" >&2
fi
exit 0
