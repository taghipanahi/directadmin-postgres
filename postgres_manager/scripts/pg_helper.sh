#!/bin/bash
# pg_helper.sh - privileged PostgreSQL gateway for DirectAdmin postgres_manager plugin.
# Runs as OS user 'postgres' via sudo (user GUI) or as root (hooks / admin GUI).
# Enforces per-DA-user isolation server-side: caller can only touch its own objects
# unless caller is admin/root/diradmin/postgres (or reseller owning the target).
#
# Usage: pg_helper.sh <action> --user <dauser> [--db <name>] [--role <name>] [--...]
# Password for role actions is passed via env PG_ROLE_PASS (never on cmdline).
set -u

PLUGIN_DIR="/usr/local/directadmin/plugins/postgres_manager"
CONF_FILE="${PLUGIN_DIR}/conf/pg.conf"

PGHOST="/var/run/postgresql"
PGPORT="5432"
PGUSER="postgres"
PGDATABASE="postgres"
ROLE_PREFIX="da_"

load_conf_safe() {
    local f="$1" k v
    [ -f "$f" ] || return 0
    while IFS='=' read -r k v; do
        k=$(printf '%s' "$k" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        case "$k" in \#*|"") continue ;; esac
        v=$(printf '%s' "$v" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed 's/^"//;s/"$//;s/^'"'"'//;s/'"'"'$//')
        case "$k" in PGHOST|PGPORT|PGUSER|PGDATABASE|ROLE_PREFIX) eval "$k=\"$v\"" ;; esac
    done < "$f"
}
load_conf_safe "$CONF_FILE"

# sanitize configurable prefix (set-prefix validates strictly; this is belt-and-braces)
ROLE_PREFIX=$(echo "${ROLE_PREFIX:-da_}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_]/_/g' | cut -c1-8)
case "$ROLE_PREFIX" in
    [a-z]*) ;;
    *) ROLE_PREFIX="da_" ;;
esac
[ -n "$ROLE_PREFIX" ] || ROLE_PREFIX="da_"

# Execution mode: psql/pg_dump MUST always run as the postgres OS user
# (peer auth). When the helper itself runs as root (admin/reseller GUI via
# sudo, hooks), prefix those calls with sudo -u postgres. Authorization
# NEVER trusts euid — only the SUDO_USER-derived CALLER (see check_access).
if [ "$(id -u 2>/dev/null)" = "0" ]; then _SU="sudo -n -u postgres"; else _SU=""; fi

PSQL="psql -h ${PGHOST} -p ${PGPORT} -U ${PGUSER} -d ${PGDATABASE} -v ON_ERROR_STOP=1 -q -tA"

# ---------- helpers ----------
err() { echo "ERROR: $*" >&2; }
ok()  { echo "OK: $*"; }

# caller detection: ONLY SUDO_USER (set by sudo, unforgeable) then OS identity.
# DA_CALLER/USERNAME/USER/LOGNAME are env-forgeable and must never be trusted.
detect_caller() {
    if [ -n "${SUDO_USER:-}" ]; then
        echo "$SUDO_USER" | cut -d'@' -f1
    else
        whoami 2>/dev/null || echo "unknown"
    fi
}

sanitize_fragment() {
    # lowercase, non [a-z0-9_] -> _, trim leading digits/underscores issues handled by caller
    echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_]/_/g' | cut -c1-32
}

da_prefix() {
    # owner role for a DA user: ${ROLE_PREFIX}<sanitized>
    local frag
    frag=$(sanitize_fragment "$1")
    if [ -z "$frag" ]; then frag="user"; fi
    case "$frag" in
        [a-z]*) ;;
        *) frag="u${frag}" ;;
    esac
    echo "${ROLE_PREFIX}${frag}" | cut -c1-32
}

like_esc() { # escape LIKE wildcards in an already-safe identifier (_ only)
    echo "$1" | sed 's/_/\\_/g'
}

is_admin_caller() {
    # strict: only DA admins (or root/diradmin) may change global settings
    local c="$1"
    case "$c" in
        root|diradmin) return 0 ;;
    esac
    local uconf="/usr/local/directadmin/data/users/${c}/user.conf"
    [ -f "$uconf" ] && grep -qx 'usertype=admin' "$uconf" 2>/dev/null
}

qident() { # quote identifier
    local s="$1"
    s=${s//\"/\"\"}
    printf '"%s"' "$s"
}

qlit() { # quote literal
    local s="$1"
    s=${s//\'/\'\'}
    printf "'%s'" "$s"
}

valid_suffix() {
    # suffix for db/role short name: ^[a-z][a-z0-9_]{0,30}$
    echo "$1" | grep -Eq '^[a-z][a-z0-9_]{0,30}$'
}

resolve_db() {
    # accept either full name (with prefix) or short suffix; echo full name; fail if foreign
    local prefix="$1" input="$2"
    local low
    low=$(echo "$input" | tr '[:upper:]' '[:lower:]')
    if [ "$low" = "${low#"${prefix}_"}" ]; then
        # short form
        if ! valid_suffix "$low"; then err "invalid database name '$input' (use a-z, 0-9, _, start with letter, max 31 chars)"; return 1; fi
        echo "${prefix}_${low}" | cut -c1-63
    else
        # full form: must carry our prefix
        case "$low" in
            "${prefix}_"*) ;;
            *) err "database '$input' does not belong to this account (must start with ${prefix}_)"; return 1 ;;
        esac
        if [ ${#low} -gt 63 ]; then err "database name too long"; return 1; fi
        echo "$low" | grep -Eq "^[a-z_][a-z0-9_]*$" || { err "invalid database name"; return 1; }
        echo "$low"
    fi
}

resolve_role() {
    local prefix="$1" input="$2"
    local low
    low=$(echo "$input" | tr '[:upper:]' '[:lower:]')
    if [ "$low" = "${low#"${prefix}_"}" ]; then
        if ! valid_suffix "$low"; then err "invalid username '$input' (use a-z, 0-9, _, start with letter, max 31 chars)"; return 1; fi
        echo "${prefix}_${low}" | cut -c1-63
    else
        case "$low" in
            "${prefix}_"*) ;;
            *) err "db user '$input' does not belong to this account (must start with ${prefix}_)"; return 1 ;;
        esac
        if [ "$low" = "$prefix" ]; then err "reserved name"; return 1; fi
        echo "$low" | grep -Eq "^[a-z_][a-z0-9_]*$" || { err "invalid db user name"; return 1; }
        echo "$low"
    fi
}

is_privileged() {
    # $1 = caller ; true if root/diradmin, the postgres OS user, the default
    # DA admin name, or a DA admin/reseller (via user.conf).
    # NOTE: euid is deliberately NOT trusted here — in root mode any local
    # user could invoke the helper; only the SUDO_USER-derived caller counts.
    local c="$1"
    case "$c" in
        root|diradmin|postgres|admin) return 0 ;;
    esac
    local uconf="/usr/local/directadmin/data/users/${c}/user.conf"
    if [ -f "$uconf" ] && grep -Eq '^usertype=(admin|reseller)' "$uconf" 2>/dev/null; then return 0; fi
    return 1
}

is_reseller_of() {
    # $1=reseller $2=target
    local r="$1" t="$2"
    local lst="/usr/local/directadmin/data/users/${r}/users.list"
    [ -f "$lst" ] && grep -qx "$t" "$lst" 2>/dev/null
}

check_access() {
    # $1=caller $2=target
    local caller="$1" target="$2"
    [ -n "$target" ] || { err "missing --user"; exit 2; }
    if [ "$caller" = "$target" ]; then return 0; fi
    if is_privileged "$caller"; then
        # resellers may only touch their own users
        local uconf="/usr/local/directadmin/data/users/${caller}/user.conf"
        if [ -f "$uconf" ] && grep -Eq '^usertype=reseller' "$uconf"; then
            if is_reseller_of "$caller" "$target"; then return 0; fi
            err "access denied: user '$target' is not owned by reseller '$caller'"; exit 3
        fi
        return 0
    fi
    err "access denied: '$caller' cannot manage objects of '$target'"; exit 3
}

run_psql() { # run query, print output (always as postgres OS user)
    # shellcheck disable=SC2086
    $_SU $PSQL -c "$1"
}

run_psql_db() { # $1=database $2=sql — catalog/metadata reads on a user DB
    # shellcheck disable=SC2086
    $_SU psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "$1" -v ON_ERROR_STOP=1 -q -tA -c "$2"
}

DDL_TYPES="serial bigserial smallint integer bigint varchar(255) varchar(36) char(36) text boolean timestamp timestamptz date time numeric real double+precision json jsonb uuid inet bytea"
valid_ddl_type() { # $1=lowercased type
    local w="$1" x
    for x in $DDL_TYPES; do [ "$x" = "$w" ] && return 0; done
    case "$w" in "double precision") return 0 ;; esac
    return 1
}
valid_default() { # $1=default expr — whitelist, no ; -- /* */ or backslash
    [ -z "$1" ] && return 0
    case "$1" in *\;*|*--*|*\/\**) return 1 ;; esac
    echo "$1" | grep -Eq "^[A-Za-z0-9_ '():.,+*/-]+$" || return 1
    return 0
}
check_file_confined() { # $1=RDIR $2=TFILE $3=TUSER — reject symlink, require regular file owned by user/root/postgres
    local rdir="$1" tf="$2" tuser="$3" fp="$rdir/$tf" owner
    [ -e "$fp" ] || { err "file not found: pg_backups/$tf"; return 1; }
    [ -L "$fp" ] && { err "symlinks not allowed: pg_backups/$tf"; return 1; }
    [ -L "$rdir" ] && { err "invalid backup dir"; return 1; }
    [ -f "$fp" ] || { err "not a regular file: pg_backups/$tf"; return 1; }
    owner=$(stat -c %U "$fp" 2>/dev/null || echo "?")
    case "$owner" in "$tuser"|root|postgres) ;; *) err "file must be owned by $tuser (owner: $owner)"; return 1 ;; esac
    [ -r "$fp" ] || { err "file not readable by postgres (chmod 755 ~/pg_backups && chmod 644 file)"; return 1; }
    return 0
}
single_stmt_ok() { # $1=sql — strip literals/comments then reject stacked ;
    local s noq
    s=$(printf '%s' "$1" | sed -e 's/[[:space:];]*$//')
    [ -n "$s" ] || { err "empty SQL"; return 1; }
    noq=$(printf '%s' "$s" | python3 -c '
import sys,re
s=sys.stdin.read()
s=re.sub(r"/\*.*?\*/"," ",s,flags=re.S)
s=re.sub(r"--[^\n]*"," ",s)
s=re.sub(r"\$\$.*?\$\$","$$$$",s,flags=re.S)
s=re.sub(r"\$[A-Za-z_][A-Za-z0-9_]*\$.*?\$[A-Za-z_][A-Za-z0-9_]*\$"," ",s,flags=re.S)
s=re.sub(r"'"'"'[^'"'"']*'"'"'","''",s)
s=re.sub(r"\"[^\"]*\""," ",s)
sys.stdout.write(s)')
    case "$noq" in *\;*) err "only single statements allowed (no stacked queries)"; return 1 ;; esac
    printf '%s' "$s"
    return 0
}
norm_sql_head() { # lowercase, strip leading comments/space → first 2 words
    printf '%s' "$1" | python3 -c '
import sys,re
s=sys.stdin.read()
s=re.sub(r"/\*.*?\*/"," ",s,flags=re.S)
s=re.sub(r"--[^\n]*"," ",s)
s=s.strip().lower()
sys.stdout.write(s[:60])'
}
check_table() { # $1=fulldb $2="schema.table" — verify a table/view exists there
    local sch tab
    case "$2" in
        *.*) sch="${2%%.*}"; tab="${2#*.}" ;;
        *) return 1 ;;
    esac
    sch=$(echo "$sch" | tr '[:upper:]' '[:lower:]')
    tab=$(echo "$tab" | tr '[:upper:]' '[:lower:]')
    echo "$sch" | grep -Eq '^[a-z_][a-z0-9_]*$' || return 1
    echo "$tab" | grep -Eq '^[a-z_][a-z0-9_]*$' || return 1
    [ "$(run_psql_db "$1" "SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = '${sch}' AND c.relname = '${tab}' AND c.relkind IN ('r','v','m','f');")" = "1" ] || return 1
    printf '%s|%s' "$sch" "$tab"
}

# ---------- arg parsing ----------
ACTION="${1:-}"; shift 2>/dev/null || true
TUSER=""; TDB=""; TROLE=""; TPFX=""; TFILE=""; TTBL=""; TPID=""; THEADER=""
while [ $# -gt 0 ]; do
    case "$1" in
        --user) TUSER="${2:-}"; shift 2 ;;
        --db) TDB="${2:-}"; shift 2 ;;
        --role) TROLE="${2:-}"; shift 2 ;;
        --prefix) TPFX="${2:-}"; shift 2 ;;
        --file) TFILE="${2:-}"; shift 2 ;;
        --tbl) TTBL="${2:-}"; shift 2 ;;
        --pid) TPID="${2:-}"; shift 2 ;;
        --header) THEADER="${2:-}"; shift 2 ;;
        *) err "unknown argument: $1"; exit 2 ;;
    esac
done

CALLER=$(detect_caller)

case "$ACTION" in
    test)
        run_psql "SELECT 1;" >/dev/null || { err "cannot connect to PostgreSQL at ${PGHOST}:${PGPORT} as ${PGUSER}"; exit 1; }
        ok "connection to PostgreSQL ${PGHOST}:${PGPORT} works"
        ;;
    ensure-user)
        [ -n "$TUSER" ] || { err "missing --user"; exit 2; }
        check_access "$CALLER" "$TUSER"
        PREFIX=$(da_prefix "$TUSER")
        run_psql "DO \$\$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = $(qlit "$PREFIX")) THEN CREATE ROLE $(qident "$PREFIX") NOLOGIN; END IF; END \$\$; COMMENT ON ROLE $(qident "$PREFIX") IS $(qlit "DA user ${TUSER}");" \
            || { err "ensure-user failed"; exit 1; }
        ok "owner role ${PREFIX} ready for DA user ${TUSER}"
        ;;
    stats)
        # Server-wide overview for the admin GUI: ONE query (no per-user round-trips,
        # avoids long plugin execution time on servers with many accounts).
        if ! is_privileged "$CALLER"; then err "access denied: stats is admin-only"; exit 3; fi
        echo "---DATABASES---"
        run_psql "SELECT d.datname::text || '|' || COALESCE(pg_get_userbyid(d.datdba),'?')::text || '|' || pg_database_size(d.datname)::text FROM pg_database d WHERE NOT d.datistemplate AND d.datname <> 'postgres' ORDER BY 1;" \
            || { err "stats databases failed"; exit 1; }
        echo "---ROLES---"
        run_psql "SELECT r.rolname::text || '|' || CASE WHEN r.rolcanlogin THEN 'login' ELSE 'nologin' END FROM pg_roles r WHERE r.rolname LIKE $(qlit "$(like_esc "$ROLE_PREFIX")%") ESCAPE '\\' ORDER BY 1;" \
            || { err "stats roles failed"; exit 1; }
        ;;
    get-prefix)
        # read-only: report configured prefix (any caller)
        echo "ROLE_PREFIX=${ROLE_PREFIX}"
        ;;
    server-checks)
        # Read-only server overview for the admin GUI: key GUCs + active
        # pg_hba.conf rules. Needs superuser (SHOW hba_file) => runs as
        # postgres OS user; restricted to DA admins.
        if ! is_admin_caller "$CALLER"; then err "access denied: server checks are admin-only"; exit 3; fi
        echo "---SETTINGS---"
        run_psql "SELECT name || '=' || setting FROM pg_settings WHERE name IN ('server_version','port','listen_addresses','ssl','password_encryption','max_connections') ORDER BY 1;" \
            || { err "settings query failed"; exit 1; }
        echo "---HBA---"
        HBA=$(run_psql "SHOW hba_file;" | head -1)
        [ -n "$HBA" ] && [ -f "$HBA" ] || { err "hba file not found"; exit 1; }
        grep -vE '^[[:space:]]*#' "$HBA" | grep -vE '^[[:space:]]*$' || echo "(no active rules)"
        ;;
    tables)
        # List user tables/views of one DB (catalog metadata only).
        [ -n "$TUSER" ] && [ -n "$TDB" ] || { err "usage: tables --user X --db D"; exit 2; }
        check_access "$CALLER" "$TUSER"
        PREFIX=$(da_prefix "$TUSER")
        FULLDB=$(resolve_db "$PREFIX" "$TDB") || exit 1
        echo "---TABLES---"
        run_psql_db "$FULLDB" "SELECT n.nspname::text || '.' || c.relname::text || '|' || c.relkind::text || '|' || pg_total_relation_size(c.oid)::text || '|' || COALESCE(s.n_live_tup,0)::text FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace LEFT JOIN pg_stat_user_tables s ON s.schemaname = n.nspname AND s.relname = c.relname WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname NOT LIKE 'pg\_%' ESCAPE '\\' AND c.relkind IN ('r','v','m','f') ORDER BY 1;" \
            || { err "tables query failed"; exit 1; }
        ;;
    dump)
        # Plain SQL dump of one DB to stdout (used by download.raw).
        [ -n "$TUSER" ] && [ -n "$TDB" ] || { err "usage: dump --user X --db D"; exit 2; }
        check_access "$CALLER" "$TUSER"
        PREFIX=$(da_prefix "$TUSER")
        FULLDB=$(resolve_db "$PREFIX" "$TDB") || exit 1
        if command -v timeout >/dev/null 2>&1; then TQ="timeout -s KILL 540"; else TQ=""; fi
        # NOTE: $TQ/$_SU intentionally unquoted
        # shellcheck disable=SC2086
        $TQ $_SU pg_dump -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${FULLDB}" \
            -Fp --no-owner --clean --if-exists || { err "pg_dump failed"; exit 1; }
        ;;
    restore)
        # Restore a .sql file (uploaded by the user via FTP/File Manager to
        # ~/pg_backups/) into one of their DBs. Runs under SET ROLE to the
        # account owner group so created objects get correct ownership.
        # Continues on per-statement errors (ON_ERROR_STOP=0) and reports.
        [ -n "$TUSER" ] && [ -n "$TDB" ] && [ -n "$TFILE" ] || { err "usage: restore --user X --db D --file name.sql"; exit 2; }
        check_access "$CALLER" "$TUSER"
        PREFIX=$(da_prefix "$TUSER")
        FULLDB=$(resolve_db "$PREFIX" "$TDB") || exit 1
        case "$TFILE" in
            *..*|*/*|.|..) err "invalid file name"; exit 2 ;;
        esac
        case "$TFILE" in
            *.sql) ;;
            *) err "only .sql files can be restored"; exit 2 ;;
        esac
        if ! echo "$TFILE" | grep -Eq '^[A-Za-z0-9_.-]+\.sql$'; then err "invalid file name"; exit 2; fi
        RDIR="/home/${TUSER}/pg_backups"
        check_file_confined "$RDIR" "$TFILE" "$TUSER" || exit 2
        SZ=$(stat -c%s "${RDIR}/${TFILE}" 2>/dev/null || echo 0)
        [ "$SZ" -le 104857600 ] || { err "file too large (>100MB); restore via SSH psql instead"; exit 2; }
        OWNER="$PREFIX"
        LOG=$(mktemp /tmp/pgrst.XXXXXX.log) || { err "mktemp failed"; exit 1; }
        trap 'rm -f "$LOG"' EXIT INT TERM
        # root-made tmp files must be writable by the postgres runner
        [ "$(id -u 2>/dev/null)" = "0" ] && chown postgres:postgres "$LOG" || true
        if command -v timeout >/dev/null 2>&1; then TQ="timeout -s KILL 540"; else TQ=""; fi
        QR=$(qident "$OWNER")
        # NOTE: $TQ/$_SU intentionally unquoted
        # shellcheck disable=SC2086
        [ -L "${RDIR}/${TFILE}" ] && { err "symlink detected (race)"; exit 2; }
        RP=$(realpath -m "${RDIR}/${TFILE}" 2>/dev/null || echo "${RDIR}/${TFILE}")
        case "$RP" in "${RDIR}/"*) ;; *) err "file escaped backup dir"; exit 2 ;; esac
        { printf 'SET ROLE %s;\n' "$QR"; cat "${RDIR}/${TFILE}"; } | \
            $TQ $_SU psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${FULLDB}" \
                -X -q -v ON_ERROR_STOP=0 >"$LOG" 2>&1
        rc=$?
        ERRS=$(grep -c '^ERROR:' "$LOG" 2>/dev/null || true)
        WARNS=$(grep -c '^WARNING:' "$LOG" 2>/dev/null || true)
        echo "---RESTORE-LOG (tail)---"
        tail -25 "$LOG"
        echo "---SUMMARY---"
        echo "errors=${ERRS} warnings=${WARNS} rc=${rc}"
        rm -f "$LOG"; trap - EXIT INT TERM
        if [ $rc -ne 0 ]; then err "restore failed to run (rc=$rc)"; exit 1; fi
        ok "restore finished: ${ERRS} error(s), ${WARNS} warning(s)"
        ;;
    activity)
        # Live server overview for admins: sessions, DB sizes, lock summary.
        if ! is_admin_caller "$CALLER"; then err "access denied: activity is admin-only"; exit 3; fi
        echo "---SESSIONS---"
        run_psql "SELECT pid::text || '|' || COALESCE(usename,'?')::text || '|' || COALESCE(datname,'?')::text || '|' || COALESCE(state,'?')::text || '|' || COALESCE(EXTRACT(EPOCH FROM (now() - query_start))::int::text,'0') || '|' || COALESCE(replace(replace(left(query,120), '|', '/'), chr(10), ' '),'') FROM pg_stat_activity WHERE datname IS NOT NULL AND pid <> pg_backend_pid() ORDER BY query_start;" \
            || { err "sessions query failed"; exit 1; }
        echo "---DBSIZES---"
        run_psql "SELECT datname::text || '|' || pg_database_size(datname)::text FROM pg_database WHERE datistemplate = false ORDER BY pg_database_size(datname) DESC;" \
            || { err "sizes query failed"; exit 1; }
        echo "---LOCKS---"
        run_psql "SELECT mode::text || '|' || count(*)::text FROM pg_locks GROUP BY mode ORDER BY count(*) DESC;" \
            || { err "locks query failed"; exit 1; }
        ;;
    kill-session)
        if ! is_admin_caller "$CALLER"; then err "access denied: kill is admin-only"; exit 3; fi
        echo "$TPID" | grep -Eq '^[0-9]+$' || { err "bad pid"; exit 2; }
        run_psql "SELECT CASE WHEN pid = pg_backend_pid() THEN 'self' WHEN pg_terminate_backend(pid) THEN 'killed' ELSE 'failed' END FROM (SELECT ${TPID}::int AS pid) t;" \
            || { err "terminate query failed"; exit 1; }
        ;;
    export-csv)
        # Stream table contents as CSV: COPY (SELECT *) TO STDOUT.
        # Runs under SET ROLE to the user's role; leading prelude echo is
        # stripped by the GUI parser (same as query results).
        [ -n "$TUSER" ] && [ -n "$TDB" ] && [ -n "$TTBL" ] || { err "usage: export-csv --user X --db D --tbl schema.table"; exit 2; }
        check_access "$CALLER" "$TUSER"
        PREFIX=$(da_prefix "$TUSER")
        FULLDB=$(resolve_db "$PREFIX" "$TDB") || exit 1
        IDS=$(check_table "$FULLDB" "$TTBL") || { err "unknown table '$TTBL'"; exit 2; }
        SCH="${IDS%%|*}"; TAB="${IDS#*|}"
        if [ -n "$TROLE" ]; then
            FULLROLE=$(resolve_role "$PREFIX" "$TROLE") || exit 1
        else
            FULLROLE="$PREFIX"
        fi
        if command -v timeout >/dev/null 2>&1; then TQ="timeout -s KILL 540"; else TQ=""; fi
        QR=$(qident "$FULLROLE")
        # NOTE: $TQ/$_SU intentionally unquoted
        # shellcheck disable=SC2086
        { printf 'SET ROLE %s;\n' "$QR"; printf 'COPY (SELECT * FROM "%s"."%s") TO STDOUT WITH (FORMAT CSV, HEADER true);\n' "$SCH" "$TAB"; } | \
            $TQ $_SU psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${FULLDB}" \
                -X -q -v ON_ERROR_STOP=1 || { err "export failed"; exit 1; }
        ;;
    import-csv)
        # Load a server-side .csv (~/pg_backups/, postgres-readable) into one
        # of the user's tables. Runs as superuser because server-side COPY
        # FROM requires it — but file (validated, confined to pg_backups) and
        # table (verified in the user's own DB) bound the blast radius.
        [ -n "$TUSER" ] && [ -n "$TDB" ] && [ -n "$TTBL" ] && [ -n "$TFILE" ] || { err "usage: import-csv --user X --db D --tbl schema.table --file name.csv [--header yes|no]"; exit 2; }
        check_access "$CALLER" "$TUSER"
        PREFIX=$(da_prefix "$TUSER")
        FULLDB=$(resolve_db "$PREFIX" "$TDB") || exit 1
        IDS=$(check_table "$FULLDB" "$TTBL") || { err "unknown table '$TTBL'"; exit 2; }
        SCH="${IDS%%|*}"; TAB="${IDS#*|}"
        case "$TFILE" in
            *..*|*/*|.|..) err "invalid file name"; exit 2 ;;
        esac
        case "$TFILE" in
            *.csv) ;;
            *) err "only .csv files can be imported"; exit 2 ;;
        esac
        if ! echo "$TFILE" | grep -Eq '^[A-Za-z0-9_.-]+\.csv$'; then err "invalid file name"; exit 2; fi
        RDIR="/home/${TUSER}/pg_backups"
        check_file_confined "$RDIR" "$TFILE" "$TUSER" || exit 2
        SZ=$(stat -c%s "${RDIR}/${TFILE}" 2>/dev/null || echo 0)
        [ "$SZ" -le 104857600 ] || { err "file too large (>100MB)"; exit 2; }
        case "${THEADER:-yes}" in
            yes) HDR="HEADER true" ;;
            no) HDR="HEADER false" ;;
            *) err "bad --header (yes|no)"; exit 2 ;;
        esac
        [ -L "${RDIR}/${TFILE}" ] && { err "symlink detected (race)"; exit 2; }
        RP=$(realpath -m "${RDIR}/${TFILE}" 2>/dev/null || echo "${RDIR}/${TFILE}")
        case "$RP" in "${RDIR}/"*) ;; *) err "file escaped backup dir"; exit 2 ;; esac
        FP=$(printf '%s' "${RDIR}/${TFILE}" | sed "s/'/''/g")
        if command -v timeout >/dev/null 2>&1; then TQ="timeout -s KILL 540"; else TQ=""; fi
        # NOTE: $TQ/$_SU intentionally unquoted
        # shellcheck disable=SC2086
        $TQ $_SU psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${FULLDB}" \
            -X -q -v ON_ERROR_STOP=1 -tA \
            -c "COPY \"${SCH}\".\"${TAB}\" FROM '${FP}' WITH (FORMAT CSV, ${HDR});" \
            || { err "import failed"; exit 1; }
        ;;
    query)        # Run ONE SQL statement inside the user's own DB, contained via
        # SET ROLE to the user's own login role: superuser-only operations
        # (pg_read_file, COPY..PROGRAM, cross-DB access, ...) are denied
        # under the assumed role. statement_timeout guards runaway queries.
        # Fresh psql session per call => no state leaks between queries.
        # SQL arrives via PG_SQL env (never cmdline) and a temp file
        # (never embedded in another SQL string => no quoting issues).
        [ -n "$TUSER" ] && [ -n "$TDB" ] && [ -n "$TROLE" ] || { err "usage: query --user X --db D --role R (SQL via PG_SQL env)"; exit 2; }
        check_access "$CALLER" "$TUSER"
        PREFIX=$(da_prefix "$TUSER")
        FULLDB=$(resolve_db "$PREFIX" "$TDB") || exit 1
        FULLROLE=$(resolve_role "$PREFIX" "$TROLE") || exit 1
        [ -n "${PG_SQL:-}" ] || { err "missing SQL (PG_SQL env)"; exit 2; }
        [ "${#PG_SQL}" -le 20000 ] || { err "SQL too long (max 20000 chars)"; exit 2; }
        STMT=$(single_stmt_ok "$PG_SQL") || exit 2
        # DDL with raw expressions must go through the dedicated 'ddl'
        # action (server-side identifier/type/DEFAULT whitelist). Block it here
        # on the NORMALIZED head (leading comments stripped, lowercased).
        HEAD=$(norm_sql_head "$STMT")
        case "$HEAD" in
            create\ table*|alter\ table*\ add*column*)
                err "use the ddl action for CREATE/ADD COLUMN (DEFAULT whitelist enforced server-side)"; exit 2 ;;
        esac
        TMPF=$(mktemp /tmp/pgqmgr.XXXXXX.sql) || { err "mktemp failed"; exit 1; }
        trap 'rm -f "$TMPF"' EXIT INT TERM
        printf '%s\n' "$STMT" > "$TMPF"
        chmod 600 "$TMPF"
        # root-made tmp files must be readable by the postgres runner
        [ "$(id -u 2>/dev/null)" = "0" ] && chown postgres:postgres "$TMPF" || true
        if command -v timeout >/dev/null 2>&1; then TQ="timeout -s KILL 25"; else TQ=""; fi
        QR=$(qident "$FULLROLE")
        # NOTE: $TQ/$_SU intentionally unquoted
        # shellcheck disable=SC2086
        { printf "SET ROLE %s;\nSET statement_timeout = '15s';\n" "$QR"; cat "$TMPF"; } | \
            $TQ $_SU psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${FULLDB}" \
                -X -q -v ON_ERROR_STOP=1 -A "-F$(printf '\t')" -P footer=off
        rc=$?
        rm -f "$TMPF"; trap - EXIT INT TERM
        [ $rc -eq 0 ] || { err "query failed"; exit 1; }
        ;;
    ddl) # Structured DDL: CREATE TABLE or ADD COLUMN with server-side whitelist.
        # PG_DDL env lines: name|type|nn(0/1)|default|pk(0/1). --tbl names target.
        # kind from --header: "create" or "addcol".
        [ -n "$TUSER" ] && [ -n "$TDB" ] && [ -n "$TROLE" ] && [ -n "$TTBL" ] || { err "usage: ddl --user X --db D --role R --tbl schema.table --header create|addcol (spec via PG_DDL env)"; exit 2; }
        check_access "$CALLER" "$TUSER"
        PREFIX=$(da_prefix "$TUSER")
        FULLDB=$(resolve_db "$PREFIX" "$TDB") || exit 1
        FULLROLE=$(resolve_role "$PREFIX" "$TROLE") || exit 1
        case "$THEADER" in create|addcol) ;; *) err "bad ddl kind"; exit 2 ;; esac
        [ -n "${PG_DDL:-}" ] || { err "missing PG_DDL spec"; exit 2; }
        [ "${#PG_DDL}" -le 10000 ] || { err "DDL spec too long"; exit 2; }
        SCH="${TTBL%%.*}"; TAB="${TTBL#*.}"
        SCH=$(echo "$SCH" | tr '[:upper:]' '[:lower:]'); TAB=$(echo "$TAB" | tr '[:upper:]' '[:lower:]')
        echo "$SCH" | grep -Eq '^[a-z_][a-z0-9_]*$' || { err "bad schema"; exit 2; }
        if [ "$THEADER" = "create" ]; then
            [ "$SCH" = "public" ] || { err "tables must be created in public schema"; exit 2; }
            echo "$TAB" | grep -Eq '^[a-z_][a-z0-9_]{0,62}$' || { err "bad table name"; exit 2; }
        else
            IDS=$(check_table "$FULLDB" "$SCH.$TAB") || { err "unknown table '$TTBL'"; exit 2; }
        fi
        COLDEFS=""; PKS=""
        while IFS='|' read -r cn ct nn dv pk rest; do
            [ -n "$rest" ] && { err "bad DDL spec"; exit 2; }
            cn=$(echo "${cn:-}" | tr '[:upper:]' '[:lower:]'); ct=$(echo "${ct:-}" | tr '[:upper:]' '[:lower:]')
            echo "$cn" | grep -Eq '^[a-z_][a-z0-9_]{0,62}$' || { err "bad column name '$cn'"; exit 2; }
            valid_ddl_type "$ct" || { err "bad column type '$ct'"; exit 2; }
            case "${nn:-0}" in 0|1) ;; *) err "bad nn flag"; exit 2 ;; esac
            case "${pk:-0}" in 0|1) ;; *) err "bad pk flag"; exit 2 ;; esac
            valid_default "${dv:-}" || { err "bad DEFAULT expression"; exit 2; }
            cd2="$(qident "$cn") $(printf '%s' "$ct")"
            [ "${nn:-0}" = "1" ] && cd2="$cd2 NOT NULL"
            [ -n "${dv:-}" ] && cd2="$cd2 DEFAULT ${dv}"
            if [ "$THEADER" = "create" ]; then
                COLDEFS="${COLDEFS}${COLDEFS:+, }$cd2"
                [ "${pk:-0}" = "1" ] && PKS="${PKS}${PKS:+, }$(qident "$cn")"
            else
                COLDEFS="$cd2"
            fi
        done <<EOF
$PG_DDL
EOF
        [ -n "$COLDEFS" ] || { err "no columns"; exit 2; }
        if [ "$THEADER" = "create" ]; then
            [ -n "$PKS" ] && COLDEFS="$COLDEFS, PRIMARY KEY ($PKS)"
            DDL="CREATE TABLE $(qident "$SCH").$(qident "$TAB") ($COLDEFS)"
        else
            DDL="ALTER TABLE $(qident "$SCH").$(qident "$TAB") ADD COLUMN $COLDEFS"
        fi
        TMPF=$(mktemp /tmp/pgddl.XXXXXX.sql) || { err "mktemp failed"; exit 1; }
        trap 'rm -f "$TMPF"' EXIT INT TERM
        printf '%s\n' "$DDL" > "$TMPF"
        chmod 600 "$TMPF"
        [ "$(id -u 2>/dev/null)" = "0" ] && chown postgres:postgres "$TMPF" || true
        if command -v timeout >/dev/null 2>&1; then TQ="timeout -s KILL 25"; else TQ=""; fi
        QR=$(qident "$FULLROLE")
        # shellcheck disable=SC2086
        { printf "SET ROLE %s;\nSET statement_timeout = '15s';\n" "$QR"; cat "$TMPF"; } | \
            $TQ $_SU psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${FULLDB}" \
                -X -q -v ON_ERROR_STOP=1 || { err "ddl failed"; exit 1; }
        rm -f "$TMPF"; trap - EXIT INT TERM
        ok "ddl done"
        ;;
    prereqs)
        # Read-only prerequisite check: OS + pkg manager + binaries + cluster. Any caller.
        echo "---OS---"
        if [ -f /etc/os-release ]; then grep -E '^(PRETTY_NAME|ID|VERSION_ID)=' /etc/os-release 2>/dev/null || cat /etc/os-release | head -3;
        else uname -srm 2>/dev/null || echo "os=unknown"; fi
        if command -v apt-get >/dev/null 2>&1; then echo "pkgmgr=apt";
        elif command -v dnf >/dev/null 2>&1; then echo "pkgmgr=dnf";
        elif command -v yum >/dev/null 2>&1; then echo "pkgmgr=yum";
        else echo "pkgmgr=none"; fi
        for b in psql sudo python3; do
            if command -v "$b" >/dev/null 2>&1; then echo "$b=found $(command -v "$b")";
            else echo "$b=missing"; fi
        done
        echo "pg_lsclusters=$([ -x /usr/bin/pg_lsclusters ] && echo available || echo optional)"
        echo "---CLUSTER---"
        if command -v pg_lsclusters >/dev/null 2>&1; then pg_lsclusters 2>&1 || echo "(pg_lsclusters failed)";
        elif command -v systemctl >/dev/null 2>&1; then systemctl is-active postgresql 2>&1 || systemctl status postgresql --no-pager 2>&1 | head -5 || echo "(no cluster info)";
        else echo "(no cluster tool: Debian uses pg_lsclusters, RHEL uses systemctl)"; fi
        echo "---CONNECT---"
        if $_SU psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" -c "SELECT version();" 2>&1 | head -3; then :; else echo "connect=FAILED"; fi
        ;;
    pg-install)
        # Install PostgreSQL + deps via apt (Debian/Ubuntu). Root only + DA admin.
        # Fixed command, no user-controlled args — safe to expose with POST guard in GUI.
        [ "$(id -u 2>/dev/null)" = "0" ] || { err "pg-install must run as root"; exit 3; }
        if ! is_admin_caller "$CALLER"; then err "access denied: pg-install is admin-only"; exit 3; fi
        command -v apt-get >/dev/null 2>&1 || { err "apt-get not found (only Debian/Ubuntu supported)"; exit 1; }
        export DEBIAN_FRONTEND=noninteractive
        if command -v timeout >/dev/null 2>&1; then TQ="timeout -s KILL 600"; else TQ=""; fi
        # shellcheck disable=SC2086
        $TQ apt-get update && $TQ apt-get install -y postgresql sudo python3             || { err "apt install failed"; exit 1; }
        ok "PostgreSQL installed (check status with pg_lsclusters)"
        ;;
    set-prefix)
        # Change global ROLE_PREFIX in pg.conf. Must run as root AND be
        # requested by a DA admin (sudoers allows all users to invoke it,
        # so authorization is enforced here, not by sudo).
        [ "$(id -u)" = "0" ] || { err "set-prefix must run as root"; exit 3; }
        if ! is_admin_caller "$CALLER"; then err "access denied: prefix change is admin-only"; exit 3; fi
        NEW=$(echo "$TPFX" | tr '[:upper:]' '[:lower:]')
        if ! echo "$NEW" | grep -Eq '^[a-z][a-z0-9_]{0,7}$'; then
            err "invalid prefix '$TPFX' (1-8 chars: a-z, 0-9, _, start with letter; e.g. da_)"
            exit 2
        fi
        if grep -Eq '^[[:space:]]*ROLE_PREFIX=' "$CONF_FILE" 2>/dev/null; then
            sed -i "s|^[[:space:]]*ROLE_PREFIX=.*|ROLE_PREFIX=\"${NEW}\"|" "$CONF_FILE" \
                || { err "could not update $CONF_FILE"; exit 1; }
        else
            echo "ROLE_PREFIX=\"${NEW}\"" >> "$CONF_FILE" || { err "could not update $CONF_FILE"; exit 1; }
        fi
        ok "prefix changed to '${NEW}' (applies to NEW objects; existing databases/roles keep old names)"
        ;;
    da-users)
        # List DA usernames (all, or owned by a reseller). Reads DA data
        # files => must run as root; admin/reseller GUIs call it via sudo.
        # --user here optionally names a RESELLER whose users to list.
        [ "$(id -u 2>/dev/null)" = "0" ] || { err "da-users must run as root"; exit 3; }
        if [ -n "$TUSER" ]; then
            if [ "$CALLER" != "$TUSER" ] && ! is_admin_caller "$CALLER"; then err "access denied"; exit 3; fi
            LST="/usr/local/directadmin/data/users/${TUSER}/users.list"
            [ -f "$LST" ] || { err "no users under $TUSER"; exit 1; }
            grep -vE '^[[:space:]]*(#|$)' "$LST" 2>/dev/null || true
        else
            if ! is_admin_caller "$CALLER"; then err "access denied: admin-only"; exit 3; fi
            for _c in /usr/local/directadmin/data/users/*/user.conf; do
                [ -f "$_c" ] || continue
                basename "$(dirname "$_c")"
            done
        fi
        ;;
    list)
        [ -n "$TUSER" ] || { err "missing --user"; exit 2; }
        check_access "$CALLER" "$TUSER"
        PREFIX=$(da_prefix "$TUSER")
        echo "PREFIX=${PREFIX}"
        echo "---DATABASES---"
        # full names starting with prefix_ OR owned by prefix
        run_psql "SELECT d.datname::text || '|' || COALESCE(pg_get_userbyid(d.datdba),'?')::text || '|' || pg_database_size(d.datname)::text FROM pg_database d WHERE d.datname LIKE $(qlit "$(like_esc "$PREFIX")\\_%") ESCAPE '\\' OR pg_get_userbyid(d.datdba) = $(qlit "$PREFIX") ORDER BY 1;" \
            || { err "list databases failed"; exit 1; }
        echo "---ROLES---"
        run_psql "SELECT r.rolname::text || '|' || CASE WHEN r.rolcanlogin THEN 'login' ELSE 'nologin' END FROM pg_roles r WHERE r.rolname LIKE $(qlit "$(like_esc "$PREFIX")\\_%") ESCAPE '\\' OR r.rolname = $(qlit "$PREFIX") ORDER BY 1;" \
            || { err "list roles failed"; exit 1; }
        ;;
    create-db)
        [ -n "$TUSER" ] && [ -n "$TDB" ] || { err "usage: create-db --user X --db name"; exit 2; }
        check_access "$CALLER" "$TUSER"
        PREFIX=$(da_prefix "$TUSER")
        FULL=$(resolve_db "$PREFIX" "$TDB") || exit 1
        # idempotency: fail if exists
        if run_psql "SELECT 1 FROM pg_database WHERE datname = $(qlit "$FULL");" | grep -q 1; then err "database ${FULL} already exists"; exit 1; fi
        run_psql "CREATE DATABASE $(qident "$FULL") OWNER $(qident "$PREFIX") ENCODING 'UTF8' TEMPLATE template0;" \
            || { err "CREATE DATABASE failed"; exit 1; }
        # baseline privileges: owner already has all; lock down public a bit is optional - keep defaults for compat
        ok "database ${FULL} created (owner ${PREFIX})"
        ;;
    drop-db)
        [ -n "$TUSER" ] && [ -n "$TDB" ] || { err "usage: drop-db --user X --db name"; exit 2; }
        check_access "$CALLER" "$TUSER"
        PREFIX=$(da_prefix "$TUSER")
        FULL=$(resolve_db "$PREFIX" "$TDB") || exit 1
        # terminate backends then drop
        run_psql "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = $(qlit "$FULL") AND pid <> pg_backend_pid();" >/dev/null 2>&1 || true
        run_psql "DROP DATABASE IF EXISTS $(qident "$FULL");" || { err "DROP DATABASE failed"; exit 1; }
        ok "database ${FULL} dropped"
        ;;
    create-role)
        [ -n "$TUSER" ] && [ -n "$TROLE" ] || { err "usage: create-role --user X --role name (password via PG_ROLE_PASS env)"; exit 2; }
        check_access "$CALLER" "$TUSER"
        [ -n "${PG_ROLE_PASS:-}" ] || { err "missing password (PG_ROLE_PASS env)"; exit 2; }
        [ ${#PG_ROLE_PASS} -ge 8 ] || { err "password must be at least 8 characters"; exit 2; }
        PREFIX=$(da_prefix "$TUSER")
        FULL=$(resolve_role "$PREFIX" "$TROLE") || exit 1
        if run_psql "SELECT 1 FROM pg_roles WHERE rolname = $(qlit "$FULL");" | grep -q 1; then err "role ${FULL} already exists"; exit 1; fi
        run_psql "CREATE ROLE $(qident "$FULL") LOGIN PASSWORD $(qlit "$PG_ROLE_PASS") IN ROLE $(qident "$PREFIX") NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT;" \
            || { err "CREATE ROLE failed"; exit 1; }
        ok "db user ${FULL} created"
        ;;
    drop-role)
        [ -n "$TUSER" ] && [ -n "$TROLE" ] || { err "usage: drop-role --user X --role name"; exit 2; }
        check_access "$CALLER" "$TUSER"
        PREFIX=$(da_prefix "$TUSER")
        FULL=$(resolve_role "$PREFIX" "$TROLE") || exit 1
        # remove group membership first, reassign objects to group role to allow drop
        run_psql "REASSIGN OWNED BY $(qident "$FULL") TO $(qident "$PREFIX");" >/dev/null 2>&1 || true
        run_psql "DROP OWNED BY $(qident "$FULL");" >/dev/null 2>&1 || true
        run_psql "DROP ROLE IF EXISTS $(qident "$FULL");" || { err "DROP ROLE failed (maybe it still owns objects)"; exit 1; }
        ok "db user ${FULL} dropped"
        ;;
    passwd)
        [ -n "$TUSER" ] && [ -n "$TROLE" ] || { err "usage: passwd --user X --role name (new password via PG_ROLE_PASS env)"; exit 2; }
        check_access "$CALLER" "$TUSER"
        [ -n "${PG_ROLE_PASS:-}" ] || { err "missing password (PG_ROLE_PASS env)"; exit 2; }
        [ ${#PG_ROLE_PASS} -ge 8 ] || { err "password must be at least 8 characters"; exit 2; }
        PREFIX=$(da_prefix "$TUSER")
        FULL=$(resolve_role "$PREFIX" "$TROLE") || exit 1
        run_psql "ALTER ROLE $(qident "$FULL") WITH PASSWORD $(qlit "$PG_ROLE_PASS");" || { err "ALTER ROLE failed"; exit 1; }
        ok "password for ${FULL} changed"
        ;;
    grant)
        [ -n "$TUSER" ] && [ -n "$TROLE" ] && [ -n "$TDB" ] || { err "usage: grant --user X --role R --db D"; exit 2; }
        check_access "$CALLER" "$TUSER"
        PREFIX=$(da_prefix "$TUSER")
        FULLDB=$(resolve_db "$PREFIX" "$TDB") || exit 1
        FULLROLE=$(resolve_role "$PREFIX" "$TROLE") || exit 1
        run_psql "GRANT CONNECT, CREATE, TEMPORARY ON DATABASE $(qident "$FULLDB") TO $(qident "$FULLROLE");" || { err "GRANT ON DATABASE failed"; exit 1; }
        # schema privileges inside the db (best effort)
        # shellcheck disable=SC2086
        $_SU psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${FULLDB}" -v ON_ERROR_STOP=1 -q -c "GRANT USAGE, CREATE ON SCHEMA public TO $(qident "$FULLROLE"); ALTER DEFAULT PRIVILEGES FOR ROLE $(qident "$PREFIX") IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLES TO $(qident "$FULLROLE"); ALTER DEFAULT PRIVILEGES FOR ROLE $(qident "$PREFIX") IN SCHEMA public GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO $(qident "$FULLROLE"); GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO $(qident "$FULLROLE"); GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO $(qident "$FULLROLE");" \
            || { err "GRANT inside database partially failed (role has CONNECT on DB, check schema grants)"; exit 1; }
        ok "granted ${FULLROLE} access to ${FULLDB}"
        ;;
    revoke)
        [ -n "$TUSER" ] && [ -n "$TROLE" ] && [ -n "$TDB" ] || { err "usage: revoke --user X --role R --db D"; exit 2; }
        check_access "$CALLER" "$TUSER"
        PREFIX=$(da_prefix "$TUSER")
        FULLDB=$(resolve_db "$PREFIX" "$TDB") || exit 1
        FULLROLE=$(resolve_role "$PREFIX" "$TROLE") || exit 1
        run_psql "REVOKE ALL PRIVILEGES ON DATABASE $(qident "$FULLDB") FROM $(qident "$FULLROLE");" || { err "REVOKE failed"; exit 1; }
        # shellcheck disable=SC2086
        $_SU psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${FULLDB}" -v ON_ERROR_STOP=1 -q -c "REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM $(qident "$FULLROLE"); REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public FROM $(qident "$FULLROLE"); REVOKE USAGE, CREATE ON SCHEMA public FROM $(qident "$FULLROLE");" >/dev/null 2>&1 || true
        ok "revoked ${FULLROLE} access to ${FULLDB}"
        ;;
    suspend)
        [ -n "$TUSER" ] || { err "missing --user"; exit 2; }
        check_access "$CALLER" "$TUSER"
        PREFIX=$(da_prefix "$TUSER")
        run_psql "DO \$\$ DECLARE r record; BEGIN FOR r IN SELECT rolname FROM pg_roles WHERE rolname LIKE $(qlit "$(like_esc "$PREFIX")\\_%") ESCAPE '\\' AND rolcanlogin LOOP EXECUTE format('ALTER ROLE %I NOLOGIN', r.rolname); END LOOP; END \$\$;" \
            || { err "suspend failed"; exit 1; }
        ok "all db users of ${TUSER} suspended (NOLOGIN)"
        ;;
    activate)
        [ -n "$TUSER" ] || { err "missing --user"; exit 2; }
        check_access "$CALLER" "$TUSER"
        PREFIX=$(da_prefix "$TUSER")
        run_psql "DO \$\$ DECLARE r record; BEGIN FOR r IN SELECT rolname FROM pg_roles WHERE rolname LIKE $(qlit "$(like_esc "$PREFIX")\\_%") ESCAPE '\\' LOOP EXECUTE format('ALTER ROLE %I LOGIN', r.rolname); END LOOP; END \$\$;" \
            || { err "activate failed"; exit 1; }
        ok "all db users of ${TUSER} activated (LOGIN)"
        ;;
    drop-user)
        [ -n "$TUSER" ] || { err "missing --user"; exit 2; }
        check_access "$CALLER" "$TUSER"
        PREFIX=$(da_prefix "$TUSER")
        # drop databases with prefix
        DBS=$(run_psql "SELECT datname FROM pg_database WHERE datname LIKE $(qlit "$(like_esc "$PREFIX")\\_%") ESCAPE '\\';") || { err "query failed"; exit 1; }
        for d in $DBS; do
            run_psql "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = $(qlit "$d") AND pid <> pg_backend_pid();" >/dev/null 2>&1 || true
            run_psql "DROP DATABASE IF EXISTS $(qident "$d");" >/dev/null 2>&1 || err "could not drop database $d"
        done
        # drop roles with prefix
        ROLES=$(run_psql "SELECT rolname FROM pg_roles WHERE rolname LIKE $(qlit "$(like_esc "$PREFIX")\\_%") ESCAPE '\\';") || { err "query failed"; exit 1; }
        for r in $ROLES; do
            run_psql "REASSIGN OWNED BY $(qident "$r") TO $(qident "$PREFIX");" >/dev/null 2>&1 || true
            run_psql "DROP OWNED BY $(qident "$r");" >/dev/null 2>&1 || true
            run_psql "DROP ROLE IF EXISTS $(qident "$r");" >/dev/null 2>&1 || err "could not drop role $r"
        done
        run_psql "DROP OWNED BY $(qident "$PREFIX");" >/dev/null 2>&1 || true
        run_psql "DROP ROLE IF EXISTS $(qident "$PREFIX");" >/dev/null 2>&1 || err "could not drop owner role $PREFIX"
        ok "all PostgreSQL objects of DA user ${TUSER} removed"
        ;;
    *)
        err "unknown action '$ACTION'. Valid: test ensure-user list stats get-prefix set-prefix tables query ddl dump restore server-checks activity kill-session export-csv import-csv da-users create-db drop-db create-role drop-role passwd grant revoke suspend activate drop-user"
        exit 2
        ;;
esac
