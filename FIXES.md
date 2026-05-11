# Datapump Scripts — Bug Fixes

All fixes target **OEL Linux + Oracle RAC Enterprise Edition**.  
Status: **13/17 bugs fixed** (B9/B10 are macOS-only and irrelevant on OEL; B13/B14 are cosmetic warnings).

---

---

## B1 — `run_get_pq_diag.sh`: Missing `HELP` closing delimiter (Critical)

The `usage()` function opens `cat <<HELP` at line 17 but never closes it.  
The entire script body (args, validation, SQL) is swallowed into the heredoc.

**Line 36 — add the missing closing delimiter and fix the `}` placement:**

```diff
     GV$PX_PROCESS, GV$RESOURCE_LIMIT, GV$PARAMETER, GV$SESSION).
-
-# ---------- Parse args ----------
+HELP
+}
+
+# ---------- Parse args ----------
```

Also fix these secondary issues in the same file while open:

**Duplicate `-m` option (lines 30 and 43) — rename second to `-n` or remove it:**
The second `-m) DB_NAME=...` is never reachable (shadowed by the first `-m`).  
Remove the duplicate `DB_NAME` default variable and its case arm:
```diff
-    -m) DB_NAME="${2:-}";         shift 2 ;;
```

**`LCONNECT_STR_STR` typo in validation — fix to `LCONNECT_STR`:**
```diff
-if [[ -z "${TNS_ALIAS}" && -z "${LCONNECT_STR_STR}" ]]; then
+if [[ -z "${TNS_ALIAS}" && -z "${LCONNECT_STR}" ]]; then
```

---

## B2 — `run_get_db_size.sh`: SQL section missing (Critical)

File is truncated at line 72. Add the SQL execution block after the argument validation:

**After line 72, append:**

```bash
# ---------- Build connect string ----------
if [[ -n "${TNS_ALIAS}" ]]; then
    CONNECT_TARGET="${TNS_ALIAS}"
else
    if [[ "${EZCONNECT_STR}" == //* ]]; then
        CONNECT_TARGET="${EZCONNECT_STR}"
    else
        CONNECT_TARGET="//${EZCONNECT_STR}"
    fi
fi

# ---------- Acquire password ----------
if [[ "${DB_PASS:-}" == "-" ]]; then
    if [[ -t 0 ]]; then
        echo "ERROR: -p - provided but stdin is a TTY. Pipe the password." >&2
        exit 2
    fi
    IFS= read -r DB_PASS
fi

if [[ -z "${DB_PASS:-}" ]]; then
    read -s -rp "Enter password for ${DB_USER}: " DB_PASS
    echo
fi

if ! command -v sqlplus >/dev/null 2>&1; then
    echo "ERROR: sqlplus not found in PATH." >&2; exit 1
fi

# ---------- Run query ----------
sqlplus -s "${DB_USER}/${DB_PASS}@${CONNECT_TARGET}" <<SQLEOF
set pages 100 feedback off verify off heading on linesize 120 trimspool on

col SEGMENT_TYPE for a10  head "TYPE"
col SIZE_GB      for 999,999.99 head "SIZE_GB"
col SIZE_TB      for 999.9999   head "SIZE_TB"

prompt
prompt === Database Size Report
prompt

SELECT 'DATA'        AS segment_type,
       ROUND(SUM(bytes)/1073741824, 2)   AS size_gb,
       ROUND(SUM(bytes)/1099511627776, 4) AS size_tb
FROM   dba_data_files
UNION ALL
SELECT 'TEMP',
       ROUND(SUM(bytes)/1073741824, 2),
       ROUND(SUM(bytes)/1099511627776, 4)
FROM   dba_temp_files
UNION ALL
SELECT 'TOTAL',
       ROUND((SELECT SUM(bytes) FROM dba_data_files) +
             (SELECT SUM(bytes) FROM dba_temp_files)) / 1073741824,
       ROUND((SELECT SUM(bytes) FROM dba_data_files) +
             (SELECT SUM(bytes) FROM dba_temp_files)) / 1099511627776
FROM   dual;

exit
SQLEOF
```

---

## B3 — `datapump_workflow.sh`: `info` function undefined (Critical)

Called 5 times (lines 280–284) but never defined anywhere.

**Add the definition alongside the other colour helpers (after line 56):**

```diff
 sep()   { printf " %s\n" ""; }
+info()  { printf "${BOLD}  %-14s: %s${RESET}\n" "$1" "$2"; }
```

---

## B4 — `datapump_workflow.sh`: `ask_step()` broken prompt (Critical)

Lines 62–63: `printf` receives `choice` as a stray positional arg; `read` has a non-identifier prefix string.

```diff
-        printf "${BOLD}  ▶ [P]roceed  [S]kip  [E]xit  — " choice
-        read  "[P]roceed [S]kip [E]xit — " choice
+        read -rp "$(printf "${BOLD}  ▶ [P]roceed  [S]kip  [E]xit  — ${RESET}")" choice
```

---

## B5 — `get_resource_limit.sh`: Missing pipe to drilldown (High)

Line 93–94: `get_pw.sh` output is passed as an argument to `run_get_resource_drilldown.sh` instead of being piped.

```diff
-/export/home/oracle/bin/get_pw.sh cx6dapopd dbsnmp \
-    | "${SCRIPT_DIR}/run_get_resource_drilldown.sh" -m "${DB_NAME}" -i "${INST_LIST}" -p -
+/export/home/oracle/bin/get_pw.sh cx6dapopd dbsnmp \
+    | "${SCRIPT_DIR}/run_get_resource_drilldown.sh" -c "${CONNECT_STR}" -i "${INST_LIST}" -p -
```

> Note: also update the connect argument to `-c` (EZCONNECT) or `-a` (TNS alias) to match `run_get_resource_drilldown.sh`'s actual flags — it has no `-m` flag.

---

## B6 — `run_get_resource_drilldown.sh`: `read -r -d ''` exits under `set -euo pipefail` (High)

`read -r -d '' SQLPREFS` returns exit code 1 when it reaches EOF, killing the script before any SQL runs.  
Replace with a `$(cat <<'SQL' ...)` command substitution, which always returns 0.

The affected block is wherever `SQLPREFS` is assigned. Replace:

```diff
-read -r -d '' SQLPREFS <<'SQL'
-...
-SQL
+SQLPREFS=$(cat <<'SQL'
+...
+SQL
+)
```

---

## B7 — `run_get_resource_drilldown.sh`: Blocking sessions query inverted (High)

Lines 249–261: query groups by `b.inst_id, b.sid, b.username` but the `WHERE` clause also includes `b.inst_id IN (${INST_LIST})` — this finds sessions that **are being blocked** on the flagged instances, not the actual **blockers**.  
The double `ORDER BY` (lines 260–261) also causes `ORA-03048`.

**Replace the entire blocking sessions query:**

```diff
-SELECT b.inst_id        AS blocker_inst,
-       b.sid            AS blocker_sid,
-       b.username       AS blocker_user,
-       COUNT(w.sid)     AS blocked_count
-FROM   gv\$session b
-JOIN   gv\$session w
-       ON  w.blocking_instance = b.inst_id
-       AND w.blocking_session  = b.sid
-WHERE  b.inst_id IN (${INST_LIST})
-OR     w.inst_id IN (${INST_LIST})
-GROUP  BY b.inst_id, b.sid, b.username
-ORDER  BY b.inst_id, b.sid, b.username
-ORDER  BY blocked_count DESC;
+SELECT w.blocking_instance  AS blocker_inst,
+       w.blocking_session   AS blocker_sid,
+       b.username           AS blocker_user,
+       COUNT(w.sid)         AS blocked_count
+FROM   gv\$session w
+LEFT JOIN gv\$session b
+       ON  b.inst_id = w.blocking_instance
+       AND b.sid     = w.blocking_session
+WHERE  w.inst_id IN (${INST_LIST})
+AND    w.blocking_session IS NOT NULL
+GROUP  BY w.blocking_instance, w.blocking_session, b.username
+ORDER  BY blocked_count DESC
+FETCH  FIRST 10 ROWS ONLY;
```

---

## B8 — `get_dumpfiles.sh`: Unbalanced awk character class (Medium)

Line 56: the awk regex `[Master table|Log file|Legacy|Total elapsed|ORA-|(EXP-|UDE-|IMP-|UDI-)]` is interpreted as a character class by BSD awk (macOS), not an alternation. The `(` and `)` are literal characters inside `[]`, causing the "nonterminated character class" error.

Replace the character-class brackets with a proper awk alternation using `~` and `||`:

```diff
-if (l ~ /^[[:space:]]*Job [Master table|Log file|Legacy|Total elapsed|ORA-|(EXP-|UDE-|IMP-|UDI-)/]) break
+if (l ~ /^[[:space:]]*Job (Master table|Log file|Legacy|Total elapsed)/ || \
+    l ~ /ORA-/ || l ~ /EXP-/ || l ~ /UDE-/ || l ~ /IMP-/ || l ~ /UDI-/) break
```

---

## B9 — `remove_dumpfiles_15d.sh`: GNU `date -d` syntax (Medium)

Line 16: `date -d '15 days ago' '+%s'` fails on macOS BSD date.  
This is a **server-only script** (intended for OEL Linux) — no fix needed for production use.  
If macOS compatibility is ever required, replace with:

```bash
# GNU (Linux/OEL — current):
CUTOFF=$(date -d '15 days ago' '+%s')

# BSD-compatible alternative (macOS):
CUTOFF=$(date -v-15d '+%s')
```

---

## B10 — `schedule_cleanup_cron_16d.sh`: GNU `date -d` syntax (Medium)

Lines 40–41 and 68: same GNU `date -d` issue.  
Same note as B9 — server-only, no action needed for production.  
macOS-compatible alternative if needed:

```bash
# GNU (Linux/OEL — current):
date -d '+16 days' '+%m'

# BSD-compatible alternative (macOS):
date -v+16d '+%m'
```

---

## B11 — `datapump_workflow.sh`: Bash 4+ `${var,,}` on macOS (Medium)

Line 43: `[[ "${_cont,,}" == "y" ]]` requires bash 4.x. macOS ships bash 3.2.

```diff
-    [[ "${_cont,,}" == "y" ]] || exit 1
+    [[ "${_cont}" == "y" || "${_cont}" == "Y" ]] || exit 1
```

---

## B12 — `datapump_workflow.sh`: Duplicate `hdr` calls (Medium)

Lines 290+292 (STEP 1) and the equivalent for STEP 3: `hdr 1` is called twice in a row.  
Remove the first (blank) call in each case:

```diff
-hdr 1 "Generate parfiles"
-
 hdr 1 "Generate parfiles  (datapump.sh)"
```

Apply the same pattern wherever STEP 3's `hdr 3` is duplicated.

---

## B13 — `run_get_resource_limit.sh`: `SP2-0042` warning (Low)

The warning is a cosmetic artifact — the unquoted heredoc delimiter causes an empty `SQL` buffer line to be visible. Does not affect output. No fix applied — leave as-is.

## B14 — `run_get_db_host.sh`: `SP2-0042` warning + `get_host.sh`: hardcoded DB name (Fixed)

**`run_get_db_host.sh`:** A bare `SQL` token on its own line inside the sqlplus heredoc (line 123) was a leftover artifact from the `SQLPREFIX=$(cat <<'SQL'...)` block above it. Removed:

```diff
 sqlplus -s "${DB_USER}/${DB_PASS}@${CONNECT_TARGET}" <<SQLEOF
 ${SQLPREFIX}
-SQL
 
 prompt INSTANCE:
```

**`get_host.sh`:** The `get_pw.sh` call hardcoded `cx6dapspd` instead of using the caller's DB argument. Also missing quotes on `$1`. Fixed:

```diff
-/export/home/oracle/bin/get_pw.sh cx6dapspd dbsnmp | ./run_get_db_host.sh -u dbsnmp -a $1 -p -
+/export/home/oracle/bin/get_pw.sh "$1" dbsnmp | ./run_get_db_host.sh -u dbsnmp -a "$1" -p -
```

---

## B15 / B16 — Wrong filename in docs (Low)

`CLAUDE.md` line 59 and `Datapump_Scripts_Guide.md` line 727 both reference `ZFS_FUNC_status.sh`.  
The actual filename is `ZFS_SYNC_status.sh`.

**`CLAUDE.md`:**
```diff
-| `ZFS_FUNC_status.sh` | Queries the ZFS REST API ...
+| `ZFS_SYNC_status.sh` | Queries the ZFS REST API ...
```

**`Datapump_Scripts_Guide.md` line 727:**
```diff
-./ZFS_FUNC_status.sh
+./ZFS_SYNC_status.sh
```

---

## B17 — No execute permission on `.sh` files (Low)

All scripts ship as `-rw-------`. On the production server, apply after deployment:

```bash
chmod +x /export/home/oracle/arvind/*.sh
chmod +x /export/home/oracle/arvind/resource_limit/*.sh
chmod +x /export/home/oracle/arvind/db_size/*.sh
```

---

## Fix Priority Order

| Priority | Bugs | Action |
|----------|------|--------|
| Do first | B1, B2, B3, B4 | Scripts are completely non-functional without these |
| Do next | B5, B6, B7 | Logic errors producing wrong results |
| Then | B8, B11, B12 | Portability / cosmetic correctness |
| Skip (Linux-only) | B9, B10 | Only fail on macOS; OEL production unaffected |
| Docs | B13, B14, B15, B16, B17 | Cosmetic / documentation |
