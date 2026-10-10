#!/bin/bash
# install.sh - run by DirectAdmin plugin manager as root.
set -u
PLUGIN_DIR="/usr/local/directadmin/plugins/postgres_manager"
SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# When installing from tarball via DA, CWD is already the plugin dir; support both.
if [ -f "./plugin.conf" ]; then SRC_DIR="$(pwd)"; PLUGIN_DIR="$(pwd)"; fi

echo "=== postgres_manager install ==="

if ! command -v psql >/dev/null 2>&1; then
    echo "WARNING: psql not found. Install PostgreSQL first:"
    echo "  Debian/Ubuntu: apt install -y postgresql sudo python3"
    echo "  RHEL/Alma/Rocky: dnf install -y postgresql-server sudo python3"
    echo "  ...or use the Prerequisites box + Install button in the admin GUI."
fi
command -v sudo >/dev/null 2>&1 || { echo "ERROR: sudo not found."; exit 1; }

mkdir -p "${PLUGIN_DIR}/conf" "${PLUGIN_DIR}/data" "${PLUGIN_DIR}/scripts"
if [ "$SRC_DIR" != "$PLUGIN_DIR" ]; then
    cp -rf "${SRC_DIR}/." "${PLUGIN_DIR}/"
fi

# default conf (do not overwrite existing)
if [ ! -f "${PLUGIN_DIR}/conf/pg.conf" ]; then
    cat > "${PLUGIN_DIR}/conf/pg.conf" <<'EOF'
PGHOST="/var/run/postgresql"
PGPORT="5432"
PGUSER="postgres"
PGDATABASE="postgres"
ROLE_PREFIX="da_"
EOF
fi

# restore settings preserved across delete+reinstall (see uninstall.sh):
# the backup (outside the plugin dir) wins over the fresh default conf.
BACKUP="/root/postgres_manager_pg.conf.bak"
if [ -f "$BACKUP" ]; then
    cp -f "$BACKUP" "${PLUGIN_DIR}/conf/pg.conf" \
        && echo "Restored settings from $BACKUP (prefix kept)." || true
fi
# tolerate backups from versions without ROLE_PREFIX
grep -Eq '^[[:space:]]*ROLE_PREFIX=' "${PLUGIN_DIR}/conf/pg.conf" 2>/dev/null \
    || echo 'ROLE_PREFIX="da_"' >> "${PLUGIN_DIR}/conf/pg.conf"

# allow DA users to run helper as postgres without password (least
# privilege path used by the user-level GUI).
# Admin/reseller GUIs + hooks run the helper as ROOT because only root can
# read DA account files (user.conf/users.list). Every action re-authorizes
# via the SUDO_USER-derived caller (euid is never trusted), and psql itself
# is always executed as the postgres OS user inside the helper.
# env_keep: sudo strips the environment by default; the helper needs
# PG_ROLE_PASS (create user / change password) and PG_SQL (explorer)
# to survive sudo. Restricted to this command only.
SUDOERS="/etc/sudoers.d/da_postgres_manager"
cat > "$SUDOERS" <<EOF
Defaults!${PLUGIN_DIR}/scripts/pg_helper.sh env_keep += "PG_ROLE_PASS PG_SQL PG_DDL"
# User GUIs: any local DA unix user may run the helper as postgres (peer auth).
# Authorization is enforced INSIDE the helper via SUDO_USER + prefix isolation.
ALL ALL=(postgres) NOPASSWD: ${PLUGIN_DIR}/scripts/pg_helper.sh *
# Root-mode actions (da-users/server-checks/set-prefix/stats/activity/prereqs):
# any local user may invoke as root via this helper, but the helper itself
# re-authorizes every admin-only action via the SUDO_USER-derived caller
# (admin user.conf check) plus per-user prefix isolation. Restricting this
# line to diradmin breaks the admin GUI on servers where DA plugins run as
# the logged-in unix user, so ALL is required here by design.
ALL ALL=(root) NOPASSWD: ${PLUGIN_DIR}/scripts/pg_helper.sh *
EOF
chmod 440 "$SUDOERS"
visudo -c -f "$SUDOERS" || { echo "ERROR: sudoers syntax invalid"; exit 1; }

chmod 755 "${PLUGIN_DIR}/user/"*.html "${PLUGIN_DIR}/user/"*.raw "${PLUGIN_DIR}/admin/"*.html "${PLUGIN_DIR}/reseller/"*.html 2>/dev/null || true
chmod 755 "${PLUGIN_DIR}/scripts/"*.sh "${PLUGIN_DIR}/scripts/"*.py 2>/dev/null || true
chmod 755 "${PLUGIN_DIR}/hooks/"*.sh 2>/dev/null || true
chmod 644 "${PLUGIN_DIR}/conf/pg.conf" "${PLUGIN_DIR}/plugin.conf"
chmod 750 "${PLUGIN_DIR}/data" 2>/dev/null || true

# DirectAdmin runs as 'diradmin' and must be able to read/execute plugin
# files AND write plugin.conf (install/update finalization). Manual
# extraction as root leaves root-owned files -> "Permission denied" and
# broken plugin pages. Fix ownership (sudoers file stays root-owned).
chown root:root "${PLUGIN_DIR}/scripts/pg_helper.sh" "${PLUGIN_DIR}/scripts/install.sh" "${PLUGIN_DIR}/scripts/update.sh" 2>/dev/null || true
chmod 755 "${PLUGIN_DIR}/scripts/pg_helper.sh" 2>/dev/null || true
if id diradmin >/dev/null 2>&1; then
    chown -R diradmin:diradmin "${PLUGIN_DIR}"
    # re-harden gateway after blanket chown (must stay root-owned, non-writable by diradmin)
    chown root:root "${PLUGIN_DIR}/scripts/pg_helper.sh" "${PLUGIN_DIR}/scripts/install.sh" "${PLUGIN_DIR}/scripts/update.sh" 2>/dev/null || true
    chmod 755 "${PLUGIN_DIR}/scripts/pg_helper.sh" 2>/dev/null || true
    chown root:root "${PLUGIN_DIR}/conf/pg.conf" 2>/dev/null || true
    chmod 644 "${PLUGIN_DIR}/conf/pg.conf" 2>/dev/null || true
    echo "Ownership set to diradmin:diradmin."
else
    echo "WARNING: unix user 'diradmin' not found, ownership left as-is."
fi

# sanity: postgres reachable?
if sudo -n -u postgres psql -h "$(. ${PLUGIN_DIR}/conf/pg.conf; echo ${PGHOST})" -p "$(. ${PLUGIN_DIR}/conf/pg.conf; echo ${PGPORT})" -U postgres -d postgres -c "SELECT 1;" >/dev/null 2>&1; then
    echo "PostgreSQL connection OK."
else
    echo "WARNING: cannot connect to PostgreSQL as OS user postgres."
    echo "Check that postgresql is running and peer auth allows postgres user."
    echo "Edit ${PLUGIN_DIR}/conf/pg.conf if needed (PGHOST/PGPORT)."
fi

echo "Install done. Plugin: PostgreSQL Manager (postgres_manager)."
