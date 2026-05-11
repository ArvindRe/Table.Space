#!/usr/bin/env bash
# PGA utilisation report: current snapshot (GV$PGASTAT), N-day historical trend,
# and per-instance peak from AWR (DBA_HIST_PGASTAT).
# Emits PGACHK sentinel lines for get_pga.sh threshold detection.
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
    run_get_pga.sh [-a <TNS_alias>] [-c <EZCONNECT>] [-u dbsnmp] [-p <password>]
                   [--days N] [--format table|csv]

Examples:
    # Prompt for password; use TNS alias; 14-day history
    ./run_get_pga.sh -a PRODR --days 14

    # Supply password via stdin (preferred for automation)
    /get_pw.sh DBA_PRODR dbsnmp | ./run_get_pga.sh -a PRODR -p -

    # EZCONNECT, CSV output
    ./run_get_pga.sh -c "dbhost:1521/ORCL901" --format csv

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
    - DBSNMP needs SELECT_CATALOG_ROLE (covers GV\$PGASTAT, GV\$PARAMETER,
      DBA_HIST_PGASTAT, DBA_HIST_SNAPSHOT).
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
col INST_ID          for 99999      head "INST"
col NAME             for a40        head "METRIC"
col PGA_MB           for 999999.9   head "PGA_MB"
col TARGET_MB        for 999999.9   head "TARGET_MB"
col SNAP_TIME        for a18        head "SNAP_TIME"
col TOTAL_PGA_MB     for 999999.9   head "TOTAL_ALLOC_MB"
col INUSE_MB         for 999999.9   head "INUSE_MB"
col MAX_MB           for 999999.9   head "MAX_MB"
col FREEABLE_MB      for 999999.9   head "FREEABLE_MB"
col PEAK_PGA_MB      for 999999.9   head "PEAK_MB"
col FIRST_SNAP       for a18        head "FIRST_SNAP"
col LAST_SNAP        for a18        head "LAST_SNAP"
col PEAK_AT          for a18        head "PEAK_AT"
SQL
)
fi

# ---------- Run queries ----------
# PGACHK sentinel lines are written via DBMS_OUTPUT and parsed by get_pga.sh.
# Format: PGACHK <inst_id> <alloc_mb> <target_mb>
sqlplus -s "${DB_USER}/${DB_PASS}@${CONNECT_TARGET}" <<SQLEOF
${SQLPREFIX}

-- ── 1. Current PGA snapshot (GV\$PGASTAT, all instances) ─────────────────────
prompt
prompt === Current PGA Snapshot (GV\$PGASTAT — all instances)
prompt

SELECT inst_id,
       name,
       ROUND(value / 1024 / 1024, 1) AS pga_mb
FROM   gv\$pgastat
WHERE  name IN (
    'total PGA allocated',
    'total PGA inuse',
    'total PGA used for auto workareas',
    'maximum PGA allocated',
    'total freeable PGA memory'
)
ORDER BY inst_id, name;

-- ── 2. PGA target vs current allocation per instance ─────────────────────────
prompt
prompt === PGA Target vs Current Allocation per Instance
prompt     (pga_aggregate_target=0 means AUTO mode — pga_aggregate_limit applies)
prompt

SELECT g.inst_id,
       ROUND(g.value / 1024 / 1024, 1)              AS total_pga_mb,
       ROUND(pt.value / 1024 / 1024, 1)             AS target_mb,
       ROUND(g.value * 100
             / NULLIF(pt.value, 0), 1)              AS pct_of_target
FROM  (SELECT inst_id,
              SUM(value) AS value
       FROM   gv\$pgastat
       WHERE  name = 'total PGA allocated'
       GROUP  BY inst_id)                            g
JOIN  (SELECT inst_id, value
       FROM   gv\$parameter
       WHERE  name = 'pga_aggregate_target')         pt
       ON pt.inst_id = g.inst_id
ORDER  BY g.inst_id;

-- ── 3. Emit PGACHK sentinel lines for threshold detection ────────────────────
--    Format written to stdout: PGACHK <inst_id> <alloc_mb_int> <target_mb_int>
--    get_pga.sh greps these to decide whether to offer drilldown.
SET SERVEROUTPUT ON SIZE UNLIMITED
DECLARE
    CURSOR c IS
        SELECT g.inst_id,
               ROUND(g.value / 1024 / 1024) AS alloc_mb,
               ROUND(pt.value / 1024 / 1024) AS target_mb
        FROM  (SELECT inst_id, SUM(value) AS value
               FROM   gv\$pgastat
               WHERE  name = 'total PGA allocated'
               GROUP  BY inst_id)                    g
        JOIN  (SELECT inst_id, value
               FROM   gv\$parameter
               WHERE  name = 'pga_aggregate_target') pt
               ON pt.inst_id = g.inst_id;
BEGIN
    FOR r IN c LOOP
        DBMS_OUTPUT.PUT_LINE(
            'PGACHK ' || r.inst_id || ' ' || r.alloc_mb || ' ' || r.target_mb
        );
    END LOOP;
END;
/
SET SERVEROUTPUT OFF

-- ── 4. N-day historical trend (DBA_HIST_PGASTAT) ─────────────────────────────
prompt
prompt === PGA Historical Trend — last ${DAYS} day(s) (DBA_HIST_PGASTAT)
prompt     Requires Diagnostics Pack licence.
prompt

SELECT p.instance_number                                    AS inst_id,
       TO_CHAR(s.end_interval_time, 'DD-MON-YY HH24:MI')  AS snap_time,
       ROUND(p.value / 1024 / 1024, 1)                     AS total_pga_mb
FROM   dba_hist_pgastat  p
JOIN   dba_hist_snapshot s ON s.snap_id         = p.snap_id
                          AND s.dbid            = p.dbid
                          AND s.instance_number = p.instance_number
WHERE  p.name = 'total PGA allocated'
AND    s.end_interval_time > SYSDATE - ${DAYS}
ORDER  BY p.instance_number, s.snap_id;

-- ── 5. Peak PGA per instance over N days ─────────────────────────────────────
prompt
prompt === Peak PGA per Instance — last ${DAYS} day(s)
prompt

SELECT p.instance_number                                           AS inst_id,
       ROUND(MAX(p.value) / 1024 / 1024, 1)                       AS peak_pga_mb,
       TO_CHAR(MIN(s.end_interval_time), 'DD-MON-YY HH24:MI')     AS first_snap,
       TO_CHAR(MAX(s.end_interval_time), 'DD-MON-YY HH24:MI')     AS last_snap
FROM   dba_hist_pgastat  p
JOIN   dba_hist_snapshot s ON s.snap_id         = p.snap_id
                          AND s.dbid            = p.dbid
                          AND s.instance_number = p.instance_number
WHERE  p.name = 'total PGA allocated'
AND    s.end_interval_time > SYSDATE - ${DAYS}
GROUP  BY p.instance_number
ORDER  BY p.instance_number;

-- ── 6. Timestamp of the peak per instance ────────────────────────────────────
prompt
prompt === When Did the Peak Occur — last ${DAYS} day(s)
prompt

SELECT p.instance_number                                          AS inst_id,
       TO_CHAR(s.end_interval_time, 'DD-MON-YY HH24:MI')         AS peak_at,
       ROUND(p.value / 1024 / 1024, 1)                            AS peak_pga_mb
FROM   dba_hist_pgastat  p
JOIN   dba_hist_snapshot s ON s.snap_id         = p.snap_id
                          AND s.dbid            = p.dbid
                          AND s.instance_number = p.instance_number
WHERE  p.name = 'total PGA allocated'
AND    s.end_interval_time > SYSDATE - ${DAYS}
AND    (p.instance_number, p.value) IN (
    SELECT instance_number, MAX(value)
    FROM   dba_hist_pgastat
    WHERE  name = 'total PGA allocated'
    AND    snap_id IN (
        SELECT snap_id FROM dba_hist_snapshot
        WHERE  end_interval_time > SYSDATE - ${DAYS}
    )
    GROUP  BY instance_number
)
ORDER  BY p.instance_number;

exit
SQLEOF
