#!/usr/bin/env python3
"""Shared UI helpers for postgres_manager DirectAdmin plugin (stdlib only)."""
import os
import re
import html
import subprocess
import urllib.parse

PLUGIN_DIR = "/usr/local/directadmin/plugins/postgres_manager"
HELPER = os.path.join(PLUGIN_DIR, "scripts", "pg_helper.sh")
CONF_FILE = os.path.join(PLUGIN_DIR, "conf", "pg.conf")


def e(s):
    return html.escape(str(s), quote=True)


def get_da_user():
    for k in ("SUDO_USER", "DA_USER"):
        v = os.environ.get(k, "").strip()
        if v:
            return v.split("@")[0]
    try:
        import pwd
        return pwd.getpwuid(os.getuid()).pw_name
    except Exception:
        return "unknown"


def request_method():
    return (os.environ.get("REQUEST_METHOD") or "").upper()


def require_post():
    return request_method() == "POST"


def parse_params():
    """Merge DA env vars + QUERY_STRING.

    NOTE: never read stdin here. DirectAdmin does not pipe the request
    body to plugin GUI scripts (and never closes stdin), so any
    sys.stdin.read() hangs until DA kills the plugin -> blank page.
    All GET/POST fields arrive as environment variables instead.
    """
    p = {}
    # 1) DirectAdmin exposes GET/POST fields as env vars already; pick known keys
    for k in ("action", "db", "role", "target", "password", "password2",
              "message", "error", "dbuser", "dbname", "new_prefix", "prefix",
              "file", "tbl", "view", "off", "sql"):
        v = os.environ.get(k)
        if v is not None and v != "":
            p.setdefault(k, v)
        v2 = os.environ.get(k.upper())
        if v2 is not None and v2 != "" and k not in p:
            # avoid clobbering with unrelated UPPER env like USER/ACTION defaults
            if k in ("action", "db", "role", "target", "password", "password2",
                     "dbuser", "dbname", "new_prefix"):
                p.setdefault(k, v2)
    # 2) query string
    qs = os.environ.get("QUERY_STRING", "")
    if qs:
        for k, v in urllib.parse.parse_qsl(qs, keep_blank_values=True):
            p.setdefault(k, v)
    # 3) POST body as delivered by DA: whole urlencoded body in $POST env var
    # (e.g. POST="action=t1&new_prefix=zz_"). Never read stdin (it hangs).
    post_raw = os.environ.get("POST", "")
    if post_raw and "=" in post_raw and len(post_raw) < 256 * 1024:
        for k, v in urllib.parse.parse_qsl(post_raw, keep_blank_values=True):
            p.setdefault(k, v)
    # NOTE: no stdin reading (see docstring) - POST fields come via env.
    # normalize aliases
    if "dbname" in p and "db" not in p:
        p["db"] = p["dbname"]
    if "dbuser" in p and "role" not in p:
        p["role"] = p["dbuser"]
    return p


def load_conf():
    conf = {"PGHOST": "/var/run/postgresql", "PGPORT": "5432",
            "PGUSER": "postgres", "PGDATABASE": "postgres"}
    try:
        with open(CONF_FILE) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                conf[k.strip()] = v.strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    return conf


def helper_call(action, user=None, db=None, role=None, password=None,
               prefix=None, as_root=False, sql=None, filename=None, extra=None,
               ddl=None):
    """Call privileged helper via sudo; returns (rc, stdout, stderr).

    Normal actions run as OS user postgres (peer auth). Global settings
    (set-prefix) run as root and are authorized inside the helper.
    Ad-hoc SQL travels via PG_SQL env (never cmdline).
    """
    cmd = ["sudo", "-n"] + ([] if as_root else ["-u", "postgres"]) + [HELPER, action]
    if user:
        cmd += ["--user", user]
    if db:
        cmd += ["--db", db]
    if role:
        cmd += ["--role", role]
    if prefix:
        cmd += ["--prefix", prefix]
    if filename:
        cmd += ["--file", filename]
    if extra:
        cmd += list(extra)
    env = dict(os.environ)
    if password is not None:
        env["PG_ROLE_PASS"] = password
    if sql is not None:
        env["PG_SQL"] = sql
    if ddl is not None:
        env["PG_DDL"] = ddl
    try:
        import subprocess as _sp
        pr = _sp.Popen(cmd, stdout=_sp.PIPE, stderr=_sp.PIPE,
                       text=True, env=env)
        try:
            out, err = pr.communicate(timeout=60)
        except _sp.TimeoutExpired:
            try:
                pr.kill()
            except Exception:
                pass
            return 1, "", "helper timed out"
        out = out or ""
        if len(out.encode("utf-8", "ignore")) > 2 * 1024 * 1024:
            out = out.encode("utf-8", "ignore")[:2 * 1024 * 1024].decode("utf-8", "ignore")
            err = ((err or "") + " [truncated: output exceeded 2MB]").strip()
        return pr.returncode, out.strip(), (err or "").strip()
    except FileNotFoundError as ex:
        return 1, "", f"helper not found: {ex}"
    except Exception as ex:
        return 1, "", str(ex)


def parse_list_output(out):
    """Parse 'PREFIX=.. ---DATABASES--- rows ---ROLES--- rows' into dict."""
    prefix = ""
    dbs, roles = [], []
    section = None
    for line in (out or "").splitlines():
        line = line.strip()
        if line.startswith("PREFIX="):
            prefix = line.split("=", 1)[1].strip()
        elif line == "---DATABASES---":
            section = "db"
        elif line == "---ROLES---":
            section = "role"
        elif not line:
            continue
        elif section == "db":
            parts = line.split("|")
            if len(parts) >= 3:
                try:
                    size = int(parts[2])
                except ValueError:
                    size = 0
                dbs.append({"name": parts[0], "owner": parts[1], "size": size})
        elif section == "role":
            parts = line.split("|")
            if len(parts) >= 2:
                roles.append({"name": parts[0], "mode": parts[1]})
    return {"prefix": prefix, "dbs": dbs, "roles": roles}


def run_capped(cmd, timeout=60, max_bytes=2 * 1024 * 1024):
    """Run cmd, stream stdout up to max_bytes; returns (rc, out, err)."""
    import subprocess
    try:
        pr = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, text=True)
        try:
            out, err = pr.communicate(timeout=timeout)
        except Exception:
            try:
                pr.kill()
            except Exception:
                pass
            return 1, "", "helper timed out"
        out = out or ""
        if len(out.encode("utf-8", "ignore")) > max_bytes:
            out = out.encode("utf-8", "ignore")[:max_bytes].decode("utf-8", "ignore")
            err = ((err or "") + " [truncated: output exceeded 2MB]").strip()
        return pr.returncode, out.strip(), (err or "").strip()
    except FileNotFoundError as ex:
        return 1, "", f"helper not found: {ex}"
    except Exception as ex:
        return 1, "", str(ex)


def parse_tabular(out, max_rows=500):
    """Split psql -A tab-separated output into (columns, rows).

    Strips prelude echo lines ("SET ROLE"/"SET") the helper may emit.
    Returns ([col...], [[cell...]...]) truncated to max_rows.
    """
    lines = (out or "").splitlines()
    while lines and lines[0].strip() in ("SET ROLE", "SET"):
        lines.pop(0)
    while lines and not lines[-1].strip():
        lines.pop()
    if not lines:
        return [], []
    cols = lines[0].split("\t")
    rows = [l.split("\t") for l in lines[1:1 + max_rows]]
    return cols, rows


def is_select_like(sql):
    return re.match(r"(?is)^\s*(select|table|values|with|explain|show)\b", sql or "") is not None


def fmt_size(n):
    try:
        n = int(n)
    except (ValueError, TypeError):
        return "0 B"
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024.0
    return f"{n:.1f} TB"


def valid_suffix(name):
    return re.match(r"^[a-z][a-z0-9_]{0,30}$", name or "") is not None


def da_prefix(da_user, role_prefix=None):
    """Mirror of da_prefix() in pg_helper.sh: owner role for a DA user."""
    if role_prefix is None:
        role_prefix = load_conf().get("ROLE_PREFIX", "da_") or "da_"
    role_prefix = re.sub(r"[^a-z0-9_]", "_", role_prefix.lower())[:8] or "da_"
    frag = re.sub(r"[^a-z0-9_]", "_", (da_user or "").lower())[:32]
    if not frag:
        frag = "user"
    if not frag[0].isalpha():
        frag = "u" + frag
    return (role_prefix + frag)[:32]


def get_role_prefix():
    return load_conf().get("ROLE_PREFIX", "da_") or "da_"


def _postgres_groups():
    """Groups of the postgres OS user (for readability checks)."""
    try:
        pr = subprocess.run(["id", "-Gn", "postgres"], capture_output=True,
                            text=True, timeout=5)
        if pr.returncode == 0:
            return pr.stdout.split()
    except Exception:
        pass
    return []


def pg_read_access(path, other_bits):
    """Can the postgres OS user use path with the given other-permission bits?

    other_bits: e.g. stat.S_IXOTH (traverse) or S_IROTH|S_IXOTH (list dir)
    or S_IROTH (read file). Group membership of postgres is honored too.
    Returns (ok: bool, reason: 'ok'|'missing'|'denied').
    """
    import stat as _stat
    import grp as _grp
    try:
        st = os.stat(path)
    except OSError:
        return False, "missing"
    mode = _stat.S_IMODE(st.st_mode)
    if mode & other_bits == other_bits:
        return True, "ok"
    try:
        gname = _grp.getgrgid(st.st_gid).gr_name
    except (KeyError, OSError):
        gname = None
    if gname and gname in _postgres_groups():
        if mode & (other_bits << 3) == (other_bits << 3):
            return True, "ok"
    return False, "denied"


def parse_stats_output(out):
    """Parse server-wide stats into (dbs, roles) lists."""
    dbs, roles = [], []
    section = None
    for line in (out or "").splitlines():
        line = line.strip()
        if line == "---DATABASES---":
            section = "db"
        elif line == "---ROLES---":
            section = "role"
        elif not line:
            continue
        elif section == "db":
            parts = line.split("|")
            if len(parts) >= 3:
                try:
                    size = int(parts[2])
                except ValueError:
                    size = 0
                dbs.append({"name": parts[0], "owner": parts[1], "size": size})
        elif section == "role":
            parts = line.split("|")
            if len(parts) >= 2:
                roles.append({"name": parts[0], "mode": parts[1]})
    return dbs, roles


def render_crash(ex):
    import traceback
    import time
    import os as _os
    try:
        lp = _os.path.join(PLUGIN_DIR, "data", "ui_errors.log")
        with open(lp, "a") as f:
            f.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {type(ex).__name__}: {ex}\n{traceback.format_exc()}\n---\n")
    except Exception:
        pass
    return (page_head("PostgreSQL Manager")
            + form_style()
            + '<div class="pg">'
            + '<div style="background:#fce8e6;border:1px solid #d93025;padding:8px;margin:8px 0">'
            'Internal error. The administrator has been notified (see data/ui_errors.log).</div>'
            + '</div>')


def page_head(title):
    return f"""<div style="font-family:sans-serif;max-width:1000px">
<h2>{e(title)}</h2>"""


def back_link():
    # Evolution shows plugin pages in a minimal layout; a visible back link
    # helps navigate back. If there is tab history, go back to the previous
    # DA page; on direct entry (no history) fall through to "/" (dashboard).
    return ('<div style="margin:2px 0 10px;font-size:13px">'
            '<a href="/" onclick="if(history.length>1){history.back();return false;}">&larr; Back</a>'
            '</div>')


def page_msg(ok_msg, err_msg):
    h = ""
    if ok_msg:
        h += f'<div style="background:#e6f4ea;border:1px solid #34a853;padding:8px;margin:8px 0">{e(ok_msg)}</div>'
    if err_msg:
        h += f'<div style="background:#fce8e6;border:1px solid #d93025;padding:8px;margin:8px 0">{e(err_msg)}</div>'
    return h


def form_style():
    return """<style>
.pg table{border-collapse:collapse;width:100%}
.pg th,.pg td{border:1px solid #ccc;padding:6px;text-align:left;font-size:13px}
.pg th{background:#f5f5f5}
.pg input[type=text],.pg input[type=password],.pg select{padding:5px;width:220px}
.pg input[type=submit]{padding:5px 12px}
.pg .box{border:1px solid #ddd;padding:12px;margin:12px 0;background:#fafafa}
.pg code{background:#eee;padding:1px 4px}
</style>"""
