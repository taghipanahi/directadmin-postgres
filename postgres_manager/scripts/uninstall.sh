#!/bin/bash
# uninstall.sh - run by DirectAdmin plugin manager as root.
# Keeps DB data AND preserves settings: conf/pg.conf is backed up outside
# the plugin dir so a later delete+reinstall restores the prefix and
# connection settings automatically.
set -u
PLUGIN_DIR="/usr/local/directadmin/plugins/postgres_manager"
BACKUP="/root/postgres_manager_pg.conf.bak"
if [ -f "${PLUGIN_DIR}/conf/pg.conf" ]; then
    cp -f "${PLUGIN_DIR}/conf/pg.conf" "$BACKUP" 2>/dev/null \
        && echo "Settings backed up to $BACKUP." || true
fi
rm -f /etc/sudoers.d/da_postgres_manager
echo "postgres_manager uninstalled (databases/roles were kept)."
echo "To fully reset settings too, run: rm -f $BACKUP"
