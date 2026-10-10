# PostgreSQL Manager — DirectAdmin 1.697 plugin

English-only UI. Per-DA-user isolation. No quota limits (unlimited, per request).
PostgreSQL 15/16. No extra pip packages — only `psql`, `sudo`, `python3`.

## Layout

```
postgres_manager/
  plugin.conf
  hooks/user_txt.html admin_txt.html reseller_txt.html   # menu entries
  hooks/user_create_post.sh user_destroy_post.sh
        user_suspend_post.sh user_activate_post.sh        # lifecycle (run as root)
  scripts/install.sh uninstall.sh                        # plugin-manager lifecycle (root)
  scripts/pg_helper.sh                                   # PRIVILEGED gateway (run as postgres via sudo)
  scripts/ui_lib.py                                      # shared GUI lib (stdlib only)
  user/index.html admin/index.html reseller/index.html   # GUIs (python3, executable)
  conf/pg.conf                                           # PGHOST/PGPORT/PGUSER/ROLE_PREFIX
  images/*.svg
```

## Isolation model

- DA user `fred` → group role `da_fred` (NOLOGIN), owner of all its DBs.
- Short name `shop` typed in GUI → full `da_fred_shop` (DB or LOGIN role).
- The `da_` prefix is configurable: Admin -> PostgreSQL Manager -> Settings
  (stored as ROLE_PREFIX in conf/pg.conf; applies to NEW objects only).

## Data explorer (phpMyAdmin-like, user level)

- Per-DB "Browse" link opens `browse.html`: table list (size, row estimate),
  structure view, paginated data view (100 rows/page), and an SQL box.
- No passwords stored: statements run in a fresh psql session contained via
  `SET ROLE` to the user's own login role + `statement_timeout` 15s.
  Single statement per run; SELECT-like queries get auto `LIMIT 200`.

## Backup (user level)

- Per-DB **SQL** link downloads a plain `pg_dump` (`--no-owner --clean`)
  via a RAW endpoint (`download.raw`).
- **Restore**: upload a `.sql` file via File Manager/FTP into
  `~/pg_backups/`, then pick file + target DB in the Backup box
  (max 100MB, runs as the owner role, per-statement errors reported).

## Row/table operations (browse page)

- Per-row **Del** (ctid-based), **Insert row** form (empty = NULL),
  per-table **Empty** (TRUNCATE) and **Drop** (all with confirm).
- Per-row **Edit**, **Create table** form (columns, types, PK),
  per-column **Drop**, **Add column**, **Rename table**.
- SQL box has **Run** + **Explain**; tables have **VACUUM**/**ANALYZE**;
  per-table **CSV** export (download) and **Import CSV** from
  `~/pg_backups/*.csv` (columns must match table order).
- Admin **Live activity** page (`activity.html`): sessions with Kill,
  database sizes, locks by mode.
- GUI runs as the unix user, but every mutation goes through
  `sudo pg_helper.sh ...`. Admin/reseller GUIs run it as root (only root
  can read DA account files); `psql` itself is always executed as the
  postgres OS user inside the helper. Authorization never trusts euid —
  only the SUDO_USER-derived caller, plus per-user prefix isolation.
- Suspend → `NOLOGIN` on all login roles; activate → `LOGIN`.
- Delete DA user → drop its DBs + roles + owner role.

## Install on server (as root)

```bash
# 1. PostgreSQL 15/16 must be installed & running, e.g. Debian/Ubuntu:
apt install -y postgresql-16 sudo python3
pg_lsclusters   # must show online

# 2a. install via GUI (Plugin Manager, no SSH)
# Admin Level -> Plugin Manager -> Add Plugin -> upload postgres_manager.tar.gz -> Install.
# DA runs scripts/install.sh as root automatically (sudoers + permissions + pg.conf default).
# Then open PostgreSQL Manager (admin level) once: green "Connection OK" = ready.

# 2b. install via SSH (alternative)
mkdir -p /usr/local/directadmin/plugins/postgres_manager
tar xzf postgres_manager.tar.gz -C /usr/local/directadmin/plugins/postgres_manager/
cd /usr/local/directadmin/plugins/postgres_manager
./scripts/install.sh

# 3. check
sudo -n -u postgres ./scripts/pg_helper.sh test --user admin
cat conf/pg.conf   # adjust PGHOST/PGPORT if remote
```

`install.sh` creates `/etc/sudoers.d/da_postgres_manager`:
`ALL ALL=(postgres) NOPASSWD: /usr/local/directadmin/plugins/postgres_manager/scripts/pg_helper.sh *`

## Uninstall

Via Plugin Manager, or `./scripts/uninstall.sh` (DB data is kept).

Settings (`conf/pg.conf`: prefix, host/port) survive delete+reinstall:
uninstall backs them up to `/root/postgres_manager_pg.conf.bak` and the
next install restores them. To fully reset settings too:
`rm -f /root/postgres_manager_pg.conf.bak`.

## Notes

- Auth to PG from helper uses OS-user `postgres` peer auth (no password stored).
- App connections use the LOGIN roles + passwords set in the user panel.
- For remote apps: open 5432 in firewall + `pg_hba.conf` scram-sha-256 entry.
