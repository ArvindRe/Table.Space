#!/usr/bin/env bash
# TEMP drilldown: active sort/hash consumers, workarea spill detail, and
# session-level breakdown for flagged RAC instances.
# Invoked by get_temp_usage.sh when TEMP usage exceeds the alert threshold.
# Author: Arvind Regukumar

set -euo pipefail

# ---------- Defaults ----------
DB_USER="dbsnmp"
DB_PASS=""
TNS_ALIAS=""
EZCONNECT_STR=""
INST_LIST=""     # comma-separated instance IDs, e.g. "1,3" — set via -i

usage() {
    cat <<HELP
Usage:
    run_get_temp_drilldown.sh [-a <TNS_alias>] [-c <EZCONNECT>] [-i <inst_ids>]
                               [-u <dbsnmp>] [-p <password>]

Examples:
    # Investigate instances 1 and 3; password via stdin
    /get_pw.sh DBA_PRODR dbsnmp | ./run_get_temp_drilldown.sh -a PRODR -i 1,3 -p -

    # Single instance, prompt for password
    ./run_get_temp_drilldown.sh -a PRODR -i 2

Options:
    -a    TNS alias
    -c    EZCONNECT string (host:port/service or //host:port/service)
    -i    Comma-separated list of instance IDs to investigate (required)
    -u    DB username (default: dbsnmp)
    -p    Password; use '-' to read one line from stdin

Requirements:
    DBSNMP needs SELECT_CATALOG_ROLE (covers GV\$SORT_USAGE, GV\$SESSION,
    GV\$SQL_WORKAREA_ACTIVE, GV\$TEMP_SPACE_HEADER, GV\$PARAMETER,
    DBA_TEMP_FILES, V\$SQL).
HELP
}

# ---------- Parse args ----------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -a) TNS_ALIAS="${2:-}";        shift 2 ;;
        -c) EZCONNECT_STR="${2:-}";    shift 2 ;;
        -i) INST_LIST="${2:-}";        shift 2 ;;
        -u) DB_USER="${2:-}";          shift 2 ;;
        -p) DB_PASS="${2:-}";          shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
    esac
done

# ---------- Validate ----------
if [[ -z "${INST_LIST}" ]]; then
    echo "ERROR: -i <instance_id_list> is required." >&2; usage; exit 2
fi

# Guard against SQL injection: allow only digits and commas
if [[ ! "${INST_LIST}" =~ ^[0-9]+([,][0-9]+)*$ ]]; then
    echo "ERROR: -i must be a comma-separated list of integers (e.g. 1,3)." >&2; exit 2
fi

if [[ -z "${TNS_ALIAS}" && -z "${EZCONNECT_STR}" ]]; then
    echo "ERROR: Provide either -a (TNS alias) OR -c <EZCONNECT>." >&2; exit 2
fi

if [[ -n "${TNS_ALIAS}" && -n "${EZCONNECT_STR}" ]]; then
    echo "ERROR: Provide -a (TNS alias) or -c <EZCONNECT>, not both." >&2; usage; exit 2
fi

if ! command -v sqlplus >/dev/null 2>&1; then
    echo "ERROR: sqlplus not found in PATH. Ensure ORACLE_HOME and PATH are set." >&2; exit 1
fi

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
        echo "ERROR: -p - provided but stdin is a TTY (no data). Pipe the password or omit -p to prompt." >&2
        exit 2
    fi
    IFS= read -r DB_PASS
fi
if [[ -z "${DB_PASS:-}" ]]; then
    read -s -rp "Enter password for ${DB_USER}: " DB_PASS
    echo
fi

# ---------- Run drilldown queries ----------
# INST_LIST is validated integers-only above: safe to interpolate into SQL IN clause.
sqlplus -s "${DB_USER}/${DB_PASS}@${CONNECT_TARGET}" <<SQLEOF
set pages 1000 feedback off verify off heading on linesize 220 trimspool on

col INST_ID          for 99999       head "INST"
col TABLESPACE_NAME  for a20         head "TABLESPACE"
col FILE_NAME        for a50         head "FILE_NAME"
col TOTAL_MB         for 999,999.9   head "TOTAL_MB"
col USED_MB          for 999,999.9   head "USED_MB"
col FREE_MB          for 999,999.9   head "FREE_MB"
col PCT_USED         for 999.9       head "PCT_USED"
col USERNAME         for a25         head "USERNAME"
col SID              for 99999       head "SID"
col SERIAL#          for 9999999     head "SERIAL#"
col SQL_ID           for a13         head "SQL_ID"
col TEMP_MB          for 999,999.9   head "TEMP_MB"
col SEGTYPE          for a12         head "SEG_TYPE"
col PROGRAM          for a30         head "PROGRAM"
col MODULE           for a30         head "MODULE"
col MACHINE          for a30         head "MACHINE"
col STATUS           for a10         head "STATUS"
col OPERATION_TYPE   for a28         head "WORKAREA_OP"
col POLICY           for a10         head "POLICY"
col ACTIVE_TIME_S    for 9999999     head "ACTIVE_SEC"
col WORK_AREA_MB     for 999,999.9   head "WORKAREA_MB"
col TEMPSEG_MB       for 999,999.9   head "TEMPSEG_MB"
col PASSES           for 9999        head "PASSES"
col SQL_TEXT         for a60         head "SQL_TEXT"

-- ── 1. Tempfile detail on flagged instances ────────────────────────────────────
prompt
prompt === Instance(s) ${INST_LIST} — Tempfile Detail (GV\$TEMP_SPACE_HEADER)
prompt

SELECT h.inst_id,
       h.tablespace_name,
       f.file_name,
       ROUND(h.bytes_total / 1024 / 1024, 1) AS total_mb,
       ROUND(h.bytes_used  / 1024 / 1024, 1) AS used_mb,
       ROUND(h.bytes_free  / 1024 / 1024, 1) AS free_mb,
       ROUND(h.bytes_used * 100
             / NULLIF(h.bytes_total, 0), 1)   AS pct_used
FROM   gv\$temp_space_header h
JOIN   dba_temp_files f ON f.file_id = h.file_id
WHERE  h.inst_id IN (${INST_LIST})
ORDER BY h.inst_id, f.file_name;

-- ── 2. Top 25 active TEMP consumers by session ────────────────────────────────
-- Each row is one sort/hash/lob segment held by a session.
-- PASSES > 0 means the operation has spilled to disk at least once.
prompt
prompt === Instance(s) ${INST_LIST} — Top 25 TEMP Consumers by Session (GV\$SORT_USAGE)
prompt     PASSES > 0 = workarea spilled to disk.
prompt

SELECT u.inst_id,
       u.username,
       s.sid,
       s.serial#,
       s.sql_id,
       u.segtype,
       ROUND(SUM(u.blocks) * (
                 SELECT value FROM v\$parameter
                 WHERE  name = 'db_block_size'
             ) / 1024 / 1024, 1)             AS temp_mb,
       SUBSTR(s.program, 1, 30)              AS program,
       s.module,
       SUBSTR(s.machine, 1, 30)              AS machine,
       s.status
FROM   gv\$sort_usage u
JOIN   gv\$session s ON s.saddr   = u.session_addr
                    AND s.inst_id = u.inst_id
WHERE  u.inst_id IN (${INST_LIST})
GROUP  BY u.inst_id, u.username, s.sid, s.serial#, s.sql_id,
          u.segtype, s.program, s.module, s.machine, s.status
ORDER  BY temp_mb DESC
FETCH  FIRST 25 ROWS ONLY;

-- ── 3. Active SQL workareas on flagged instances ───────────────────────────────
-- POLICY=MANUAL overrides pga_aggregate_target — these consume temp regardless.
-- PASSES > 0 confirms disk spill is happening right now.
prompt
prompt === Instance(s) ${INST_LIST} — Active SQL Workareas (GV\$SQL_WORKAREA_ACTIVE)
prompt     POLICY=MANUAL overrides pga_aggregate_target.
prompt     PASSES > 0 = actively spilling to TEMP.
prompt

SELECT w.inst_id,
       w.sid,
       w.operation_type,
       w.policy,
       ROUND(w.active_time / 1000000, 0)          AS active_time_s,
       ROUND(w.work_area_size / 1024 / 1024, 1)   AS work_area_mb,
       ROUND(NVL(w.tempseg_size, 0) / 1024 / 1024, 1) AS tempseg_mb,
       w.passes,
       s.username,
       s.sql_id,
       s.module
FROM   gv\$sql_workarea_active w
JOIN   gv\$session             s ON s.sid     = w.sid
                                AND s.inst_id = w.inst_id
WHERE  w.inst_id IN (${INST_LIST})
ORDER  BY tempseg_mb DESC, work_area_mb DESC
FETCH  FIRST 20 ROWS ONLY;

-- ── 4. SQL text for top TEMP-consuming SQL IDs ────────────────────────────────
-- Fetches the first 60 chars of the SQL text for the top consumers identified above.
prompt
prompt === Instance(s) ${INST_LIST} — SQL Text for Top TEMP Consumers
prompt

SELECT DISTINCT
       u.inst_id,
       u.sql_id,
       SUBSTR(q.sql_text, 1, 60) AS sql_text
FROM   gv\$sort_usage u
JOIN   gv\$sql         q ON q.sql_id  = u.sql_id
                        AND q.inst_id = u.inst_id
WHERE  u.inst_id IN (${INST_LIST})
ORDER  BY u.inst_id, u.sql_id
FETCH  FIRST 15 ROWS ONLY;

-- ── 5. TEMP tablespace autoextend and maxsize awareness ───────────────────────
-- Shows whether tempfiles can grow further, and how much headroom remains.
prompt
prompt === Instance(s) ${INST_LIST} — Tempfile Autoextend / Maxsize Headroom
prompt

SELECT f.tablespace_name,
       f.file_name,
       ROUND(f.bytes      / 1024 / 1024, 1)  AS current_mb,
       ROUND(f.maxbytes   / 1024 / 1024, 1)  AS max_mb,
       ROUND((f.maxbytes - f.bytes) / 1024 / 1024, 1) AS headroom_mb,
       f.autoextensible
FROM   dba_temp_files f
ORDER  BY f.tablespace_name, f.file_name;

exit
SQLEOF
