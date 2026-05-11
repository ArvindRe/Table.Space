#!/usr/bin/env bash
# PGA drilldown: top PGA consumers per session, workarea breakdown, and
# over-allocation detail for flagged RAC instances.
# Invoked by get_pga.sh when PGA allocation exceeds the alert threshold.
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
    run_get_pga_drilldown.sh [-a <TNS_alias>] [-c <EZCONNECT>] [-i <inst_ids>]
                              [-u <dbsnmp>] [-p <password>]

Examples:
    # Investigate instances 1 and 3; password via stdin
    /get_pw.sh DBA_PRODR dbsnmp | ./run_get_pga_drilldown.sh -a PRODR -i 1,3 -p -

    # Single instance, prompt for password
    ./run_get_pga_drilldown.sh -a PRODR -i 2

Options:
    -a    TNS alias
    -c    EZCONNECT string (host:port/service or //host:port/service)
    -i    Comma-separated list of instance IDs to investigate (required)
    -u    DB username (default: dbsnmp)
    -p    Password; use '-' to read one line from stdin

Requirements:
    DBSNMP needs SELECT_CATALOG_ROLE (covers GV\$PROCESS, GV\$SESSION,
    GV\$SQL_WORKAREA_ACTIVE, GV\$PGASTAT, GV\$PARAMETER).
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

col INST_ID          for 99999      head "INST"
col SID              for 99999      head "SID"
col SERIAL#          for 9999999    head "SERIAL#"
col USERNAME         for a25        head "USERNAME"
col PROGRAM          for a35        head "PROGRAM"
col STATUS           for a10        head "STATUS"
col SQL_ID           for a14        head "SQL_ID"
col PGA_ALLOC_MB     for 99999.9    head "PGA_ALLOC_MB"
col PGA_USED_MB      for 99999.9    head "PGA_USED_MB"
col PGA_FREEABLE_MB  for 99999.9    head "FREEABLE_MB"
col PGA_MAX_MB       for 99999.9    head "PGA_MAX_MB"
col OPERATION_TYPE   for a28        head "WORKAREA_OP"
col POLICY           for a10        head "POLICY"
col ACTIVE_TIME_S    for 9999999    head "ACTIVE_SEC"
col WORK_AREA_MB     for 99999.9    head "WORKAREA_MB"
col MAX_MEM_MB       for 99999.9    head "MAX_MEM_MB"
col TEMPSEG_MB       for 99999.9    head "TEMPSEG_MB"
col PASSES           for 9999       head "PASSES"
col NAME             for a40        head "METRIC"
col PGA_MB           for 999999.9   head "PGA_MB"
col MODULE           for a30        head "MODULE"
col MACHINE          for a30        head "MACHINE"

-- ── 1. Top 20 sessions by PGA allocation on flagged instances ─────────────────
prompt
prompt === Instance(s) ${INST_LIST} — Top 20 Sessions by PGA Allocation
prompt

SELECT p.inst_id,
       s.sid,
       s.serial#,
       s.username,
       s.status,
       s.sql_id,
       SUBSTR(s.program, 1, 35)              AS program,
       s.module,
       ROUND(p.pga_alloc_mem  / 1024 / 1024, 1) AS pga_alloc_mb,
       ROUND(p.pga_used_mem   / 1024 / 1024, 1) AS pga_used_mb,
       ROUND(p.pga_freeable_mem / 1024 / 1024, 1) AS pga_freeable_mb,
       ROUND(p.pga_max_mem    / 1024 / 1024, 1) AS pga_max_mb
FROM   gv\$process p
JOIN   gv\$session s ON s.paddr   = p.addr
                    AND s.inst_id = p.inst_id
WHERE  p.inst_id IN (${INST_LIST})
AND    s.username IS NOT NULL
ORDER  BY p.pga_alloc_mem DESC
FETCH  FIRST 20 ROWS ONLY;

-- ── 2. Active SQL workareas (GV\$SQL_WORKAREA_ACTIVE) ─────────────────────────
-- Shows operations currently using PGA for sort/hash/bitmap workareas.
-- POLICY=MANUAL means the workarea overrides pga_aggregate_target — watch these.
-- PASSES > 0 means the operation has spilled to temp (disk) — a sizing warning.
prompt
prompt === Instance(s) ${INST_LIST} — Active SQL Workareas
prompt     POLICY=MANUAL overrides pga_aggregate_target.
prompt     PASSES > 0 = workarea spilled to TEMP (disk).
prompt

SELECT w.inst_id,
       w.sid,
       w.operation_type,
       w.policy,
       ROUND(w.active_time / 1000000, 0) AS active_time_s,
       ROUND(w.work_area_size / 1024 / 1024, 1) AS work_area_mb,
       ROUND(w.expected_size  / 1024 / 1024, 1) AS max_mem_mb,
       ROUND(NVL(w.tempseg_size, 0) / 1024 / 1024, 1) AS tempseg_mb,
       w.passes,
       s.username,
       s.sql_id
FROM   gv\$sql_workarea_active w
JOIN   gv\$session             s ON s.sid     = w.sid
                                AND s.inst_id = w.inst_id
WHERE  w.inst_id IN (${INST_LIST})
ORDER  BY w.work_area_size DESC
FETCH  FIRST 20 ROWS ONLY;

-- ── 3. PGA pressure: freeable memory per instance ─────────────────────────────
-- High freeable PGA that persists means Oracle is holding memory it could return
-- to the OS but has not yet. Compare to total allocated to assess true pressure.
prompt
prompt === Instance(s) ${INST_LIST} — PGA Pressure Breakdown (GV\$PGASTAT)
prompt

SELECT inst_id,
       name,
       ROUND(value / 1024 / 1024, 1) AS pga_mb
FROM   gv\$pgastat
WHERE  inst_id IN (${INST_LIST})
AND    name IN (
    'total PGA allocated',
    'total PGA inuse',
    'total PGA used for auto workareas',
    'total PGA used for manual workareas',
    'maximum PGA allocated',
    'total freeable PGA memory',
    'PGA memory freed back to OS',
    'aggregate PGA target parameter',
    'aggregate PGA auto target'
)
ORDER  BY inst_id, name;

-- ── 4. Sessions with the highest PGA high-water mark (pga_max_mem) ───────────
-- pga_max_mem is the historical peak for a session regardless of current usage.
-- Large values here point to past workload spikes not visible in current alloc.
prompt
prompt === Instance(s) ${INST_LIST} — Top 15 Sessions by PGA High-Water Mark
prompt

SELECT p.inst_id,
       s.sid,
       s.serial#,
       s.username,
       s.status,
       SUBSTR(s.program, 1, 35)              AS program,
       s.module,
       SUBSTR(s.machine, 1, 30)              AS machine,
       ROUND(p.pga_max_mem   / 1024 / 1024, 1) AS pga_max_mb,
       ROUND(p.pga_alloc_mem / 1024 / 1024, 1) AS pga_alloc_mb
FROM   gv\$process p
JOIN   gv\$session s ON s.paddr   = p.addr
                    AND s.inst_id = p.inst_id
WHERE  p.inst_id IN (${INST_LIST})
AND    s.username IS NOT NULL
ORDER  BY p.pga_max_mem DESC
FETCH  FIRST 15 ROWS ONLY;

-- ── 5. PGA aggregate target vs limit (AUTO mode awareness) ───────────────────
-- pga_aggregate_target=0 means fully automatic (PGA_AGGREGATE_LIMIT applies).
-- If limit is being hit, Oracle will abort sessions — this surfaces it early.
prompt
prompt === Instance(s) ${INST_LIST} — PGA Target and Limit Parameters
prompt

SELECT inst_id,
       name,
       ROUND(value / 1024 / 1024, 1) AS pga_mb
FROM   gv\$parameter
WHERE  inst_id IN (${INST_LIST})
AND    name IN ('pga_aggregate_target', 'pga_aggregate_limit')
ORDER  BY inst_id, name;

exit
SQLEOF
