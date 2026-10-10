#!/bin/bash
# Build a DirectAdmin-installable tarball.
set -e
cd "$(dirname "$0")"
chmod 755 postgres_manager/user/*.html postgres_manager/user/*.raw postgres_manager/admin/*.html postgres_manager/reseller/*.html postgres_manager/scripts/*.sh postgres_manager/hooks/*.sh 2>/dev/null || true
# DA Plugin Manager expects plugin.conf at the TOP LEVEL of the tarball
# (no wrapping directory) - same as official hello_world.tar.gz.
# Manual install: mkdir -p plugins/postgres_manager && tar xzf ... -C plugins/postgres_manager
# NOTE: conf/pg.conf is EXCLUDED on purpose - it holds live settings
# (prefix, host/port). install.sh recreates the default if missing, so
# URL/manual updates never clobber custom settings. Delete+reinstall is
# covered by the /root backup in install/uninstall.sh.
find postgres_manager -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null || true
find postgres_manager -name "*.pyc" -delete 2>/dev/null || true
rm -f postgres_manager.tar.gz
tar czf postgres_manager.tar.gz --exclude='./data/*' --exclude='./conf/pg.conf' -C postgres_manager .
# keep data dir in tarball
tar tzf postgres_manager.tar.gz | head -50
VERSION=$(grep ^version= postgres_manager/plugin.conf | cut -d= -f2)
printf '%s' "$VERSION" > version.html
echo "Built: $(pwd)/postgres_manager.tar.gz"
echo "Version: $VERSION -> version.html"
