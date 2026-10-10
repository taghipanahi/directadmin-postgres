#!/bin/bash
# user_destroy_post.sh - remove all PG objects of deleted DA user. Runs as root.
PLUGIN_DIR="/usr/local/directadmin/plugins/postgres_manager"
HELPER="${PLUGIN_DIR}/scripts/pg_helper.sh"
[ -x "$HELPER" ] || exit 0
[ -n "${username:-}" ] || exit 0
if id postgres >/dev/null 2>&1; then
    sudo -n -u postgres "$HELPER" drop-user --user "$username" >/dev/null 2>&1 || echo "postgres_manager: cleanup for $username had warnings" >&2
fi
exit 0
