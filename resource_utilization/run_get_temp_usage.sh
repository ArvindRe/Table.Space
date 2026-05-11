#!/usr/bin/env bash
# TEMP tablespace utilisation report:
#   1. Current tempfile allocation vs capacity (GV$TEMP_SPACE_HEADER)
#   2. Per-instance TEMP summary — used, free, total (GB)
#   3. Active TEMP consumers by session (GV$SORT_USAGE + GV$SESSION)
#   4. N-day historical peak from AWR (DBA_HIST_TBSPC_SPACE_USAGE)
# Emits TEMPCHK sentinel lines for get_temp_usage.sh threshold detection.
# Author: Arvind Regukumar

set -euo pipefail

# ---------- Defaults ----------
DB_USER="dbsnmp"
DB_PASS="${DBSNMP_PASSWORD:-}"
TNS_ALIAS=""
EZCONNECT_STR=""
DAYS=7
FORMAT="table"    # table|csv

usage() {
    cat <<HELP
Usage:
    run_get_temp_usage.sh [-a <TNS_alias>] [-c <EZCONNECT>] [-u dbsnmp] [-p <password>]
                          [--days N] [--format table|csv]

Examples:
    # Prompt for password; use TNS alias; 14-day history
    ./run_get_temp_usage.sh -a PRODR --days 14

    # Supply password via stdin (preferred for automation)
    /get_pw.sh DBA_PRODR dbsnmp | ./run_get_temp_usage.sh -a PRODR -p -

    # EZCONNECT, CSV output
    ./run_get_temp_usage.sh -c "dbhost:1521/ORCL901" --format csv

Options:
    -a        TNS alias (requires a valid tnsnames.ora entry)
    -c        EZCONNECT string (host:port/service or //host:port/service)
    -u        DB username (default: dbsnmp)
    -p        Password (use '-' to read one line from stdin; if omitted, uses
              env DBSNMP_PASSWORD or prompts securely)
    --days    Number of days of AWR history to report (default: 7)
    --format  Output format: table|csv (default: table)

Requirements:
    - sqlplus must be in PATH.
    - DBSNMP needs SELECT_CATALOG_ROLE (covers GV\$TEMP_SPACE_HEADER,
      GV\$SORT_USAGE, GV\$SESSION, DBA_HIST_TBSPC_SPACE_USAGE,
      DBA_HIST_SNAPSHOT, DBA_TABLESPACES, DBA_TEMP_FILES).
    - AWR queries require Diagnostics Pack licence.
HELP
}

# ---------- Parse args ----------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -a)       TNS_ALIAS="${2:-}";       shift 2 ;;
        -c)       EZCONNECT_STR="${2:-}";   shift 2 ;;
        -u)       DB_USER="${2:-}";         shift 2 ;;
        -p)       DB_PASS="${2:-}";         shift 2 ;;
        --days)   DAYS="${2:-7}";           shift 2 ;;
        --format) FORMAT="${2:-table}";     shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
    esac
done

# ---------- Validate ----------
if [[ -z "${TNS_ALIAS}" && -z "${EZCONNECT_STR}" ]]; then
    echo "ERROR: Provide either -a (TNS alias) OR -c <EZCONNECT>." >&2; exit 2
fi
if [[ -n "${TNS_ALIAS}" && -n "${EZCONNECT_STR}" ]]; then
    echo "ERROR: Provide -a (TNS alias) or -c <EZCONNECT>, not both." >&2; usage; exit 2
fi
if [[ ! "${DAYS}" =~ ^[0-9]+$ || "${DAYS}" -lt 1 ]]; then
    echo "ERROR: --days must be a positive integer." >&2; exit 2
fi
if [[ "${FORMAT}" != "table" && "${FORMAT}" != "csv" ]]; then
    echo "ERROR: --format must be 'table' or 'csv'." >&2; exit 2
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

# ---------- Tool check ----------
if ! command -v sqlplus >/dev/null 2>&1; then
    echo "ERROR: sqlplus not found in PATH. Ensure ORACLE_HOME and PATH are set." >&2; exit 1
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

# ---------- Format-specific SQLPlus settings ----------
if [[ "${FORMAT}" == "csv" ]]; then
    SQLPREFIX=$(cat <<'SQL'
set pages 0 feedback off verify off heading on linesize 2000 trimspool on
set markup csv on delimiter ',' quote on
SQL
)
else
    SQLPREFIX=$(cat <<'SQL'
set pages 1000 feedback off verify off heading on linesize 220 trimspool on
col INST_ID          for 99999       head "INST"
col TABLESPACE_NAME  for a20         head "TABLESPACE"
col FILE_NAME        for a60         head "FILE_NAME"
col TOTAL_MB         for 999,999.9   head "TOTAL_MB"
col USED_MB          for 999,999.9   head "USED_MB"
col FREE_MB          for 999,999.9   head "FREE_MB"
col PCT_USED         for 999.9       head "PCT_USED"
col TOTAL_GB         for 99,999.99   head "TOTAL_GB"
col USED_GB          for 99,999.99   head "USED_GB"
col FREE_GB          for 99,999.99   head "FREE_GB"
col USERNAME         for a30         head "USERNAME"
col SID              for 99999       head "SID"
col SERIAL#          for 9999999     head "SERIAL#"
col SQL_ID           for a13         head "SQL_ID"
col TEMP_MB          for 999,999.9   head "TEMP_MB"
col SEGTYPE          for a12         head "SEG_TYPE"
col PROGRAM          for a30         head "PROGRAM"
col SNAP_TIME        for a18         head "SNAP_TIME"
col PEAK_USED_GB     for 99,999.99   head "PEAK_USED_GB"
SQL
)
fi

# ---------- Run queries ----------
# TEMPCHK sentinel lines are written via DBMS_OUTPUT and parsed by get_temp_usage.sh.
# Format: TEMPCHK <inst_id> <used_mb_int> <total_mb_int>
sqlplus -s "${DB_USER}/${DB_PASS}@${CONNECT_TARGET}" <<SQLEOF
${SQLPREFIX}

-- ── 1. Tempfile allocation vs capacity per instance (GV\$TEMP_SPACE_HEADER) ──
prompt
prompt === TEMP Tablespace — Tempfile Summary (GV\$TEMP_SPACE_HEADER)
prompt

SELECT h.inst_id,
       h.tablespace_name,
       f.file_name,
       ROUND(h.bytes_total   / 1024 / 1024, 1) AS total_mb,
       ROUND(h.bytes_used    / 1024 / 1024, 1) AS used_mb,
       ROUND(h.bytes_free    / 1024 / 1024, 1) AS free_mb,
       ROUND(h.bytes_used * 100
             / NULLIF(h.bytes_total, 0), 1)     AS pct_used
FROM   gv\$temp_space_header h
JOIN   dba_temp_files f ON f.file_id = h.file_id
ORDER BY h.inst_id, h.tablespace_name, f.file_name;

-- ── 2. Per-instance TEMP summary — aggregated GB and pct ─────────────────────
prompt
prompt === TEMP Tablespace — Per-Instance Totals
prompt

SELECT h.inst_id,
       h.tablespace_name,
       ROUND(SUM(h.bytes_total) / 1073741824, 2) AS total_gb,
       ROUND(SUM(h.bytes_used)  / 1073741824, 2) AS used_gb,
       ROUND(SUM(h.bytes_free)  / 1073741824, 2) AS free_gb,
       ROUND(SUM(h.bytes_used) * 100
             / NULLIF(SUM(h.bytes_total), 0), 1)  AS pct_used
FROM   gv\$temp_space_header h
GROUP  BY h.inst_id, h.tablespace_name
ORDER  BY h.inst_id, h.tablespace_name;

-- ── 3. Emit TEMPCHK sentinel lines for threshold detection ───────────────────
--    Format: TEMPCHK <inst_id> <used_mb_int> <total_mb_int>
SET SERVEROUTPUT ON SIZE UNLIMITED
DECLARE
    CURSOR c IS
        SELECT inst_id,
               ROUND(SUM(bytes_used)  / 1024 / 1024) AS used_mb,
               ROUND(SUM(bytes_total) / 1024 / 1024) AS total_mb
        FROM   gv\$temp_space_header
        GROUP  BY inst_id;
BEGIN
    FOR r IN c LOOP
        DBMS_OUTPUT.PUT_LINE(
            'TEMPCHK ' || r.inst_id || ' ' || r.used_mb || ' ' || r.total_mb
        );
    END LOOP;
END;
/
SET SERVEROUTPUT OFF

-- ── 4. Active TEMP consumers by session (GV\$SORT_USAGE + GV\$SESSION) ────────
prompt
prompt === Active TEMP Consumers by Session (GV\$SORT_USAGE)
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
             ) / 1024 / 1024, 1)           AS temp_mb,
       SUBSTR(s.program, 1, 30)            AS program
FROM   gv\$sort_usage u
JOIN   gv\$session s ON s.saddr   = u.session_addr
                    AND s.inst_id = u.inst_id
GROUP  BY u.inst_id, u.username, s.sid, s.serial#, s.sql_id, u.segtype, s.program
ORDER  BY temp_mb DESC
FETCH  FIRST 20 ROWS ONLY;

-- ── 5. Top 10 SQL statements currently using TEMP ─────────────────────────────
prompt
prompt === Top 10 SQL Statements by Current TEMP Usage
prompt

SELECT u.inst_id,
       u.sql_id,
       u.username,
       ROUND(SUM(u.blocks) * (
                 SELECT value FROM v\$parameter
                 WHERE  name = 'db_block_size'
             ) / 1024 / 1024, 1)           AS temp_mb,
       u.segtype
FROM   gv\$sort_usage u
GROUP  BY u.inst_id, u.sql_id, u.username, u.segtype
ORDER  BY temp_mb DESC
FETCH  FIRST 10 ROWS ONLY;

-- ── 6. N-day historical TEMP peak from AWR (DBA_HIST_TBSPC_SPACE_USAGE) ──────
prompt
prompt === TEMP Historical Peak — last ${DAYS} day(s) (DBA_HIST_TBSPC_SPACE_USAGE)
prompt     Requires Diagnostics Pack licence.
prompt

SELECT s.instance_number                                           AS inst_id,
       d.tablespace_name,
       TO_CHAR(s.end_interval_time, 'DD-MON-YY HH24:MI')         AS snap_time,
       ROUND(t.tablespace_usedsize
             * (SELECT value FROM v\$parameter
                WHERE  name = 'db_block_size') / 1073741824, 2)   AS peak_used_gb
FROM   dba_hist_tbspc_space_usage t
JOIN   dba_hist_snapshot          s ON s.snap_id         = t.snap_id
                                   AND s.dbid            = t.dbid
JOIN   dba_tablespaces            d ON d.tablespace_name = (
           SELECT tablespace_name FROM dba_temp_files
           WHERE  tablespace_name = d.tablespace_name
           AND    ROWNUM = 1
       )
WHERE  t.tablespace_id IN (
           SELECT tablespace_id
           FROM   dba_hist_tbspc_space_usage
           WHERE  snap_id IN (
               SELECT snap_id FROM dba_hist_snapshot
               WHERE  end_interval_time > SYSDATE - ${DAYS}
               AND    dbid = (SELECT dbid FROM v\$database)
           )
       )
AND    s.end_interval_time > SYSDATE - ${DAYS}
AND    s.dbid = (SELECT dbid FROM v\$database)
AND    d.contents = 'TEMPORARY'
ORDER  BY s.instance_number, s.snap_id;

exit
SQLEOF
