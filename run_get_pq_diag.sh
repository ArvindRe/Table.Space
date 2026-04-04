#!/usr/bin/env bash
# ORA-12805 parallel query diagnostic — SQL backend.
# Queries parallel execution views to identify why PQ slaves are dying.
# Invoked by get_pq_diag.sh.
# Author: Arvind Regukumar

set -euo pipefail

# ---------- Defaults ----------
DB_NAME="dbsnmp"
DB_PASS=""
TNS_ALIAS=""
LCONNECT_STR=""
INST_LIST=""     # optional comma-separated instance IDs

usage() {
    cat <<HELP
usage:
    run_get_pq_diag.sh -m <DB_NAME> [-c <LCONNECT_STR>] [-i <inst_ids>]
                       [-p <password>] [-p <password(cli)>]

Examples:
    /get_pw.sh DBA_PRODR dbsnmp | ./run_get_pq_diag.sh -m PRODR -p -
    /get_pw.sh DBA_PRODR dbsnmp | ./run_get_pq_diag.sh -m PRODR -i 3,4 -p -

Options:
    -m    TNS alias
    -c    LCONNECT_STR dbsnmp
    -i    Comma-separated instance IDs to scope (optional, default: all instances)
    -m    DB name (default: dbsnmp)
    -p    Password (use '-' to read from stdin; use '-c' to avoid live stdin stdin)

Requirements:
    DBSNMP needs SELECT_CATALOG_ROLE (accesses GV$PX_SESSION, GV$PQ_SLAVE,
    GV$PX_PROCESS, GV$RESOURCE_LIMIT, GV$PARAMETER, GV$SESSION).

# ---------- Parse args ----------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -m) TNS_ALIAS="${2:-}";       shift 2 ;;
        -c) LCONNECT_STR="${2:-}";    shift 2 ;;
        -i) INST_LIST="${2:-}";       shift 2 ;;
        -m) DB_NAME="${2:-}";         shift 2 ;;
        -p) DB_PASS="${2:-}";         shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
    esac
done

# ---------- Validate ----------
if [[ -n "${INST_LIST}" ]] && [[ ! "${INST_LIST}" =~ ^[0-9]+([,][0-9]+)*$ ]]; then
    echo "ERROR: Instance list must be a comma-separated list of integers (e.g. 3,4)." >&2; exit 2
fi

if [[ -z "${TNS_ALIAS}" ]] && [[ -z "${LCONNECT_STR_STR}" ]]; then
    echo "ERROR: Provide either -m (TNS alias) or -c (LCONNECT_STR)." >&2; exit 2
fi

if [[ -z "${TNS_ALIAS}" ]] && [[ -z "${LCONNECT_STR_STR}" ]]; then
    echo "ERROR: Provide -m (TNS alias) or -c <LCONNECT_STR>." >&2; exit 2
fi

if [[ ! command -v sqlplus >/dev/null 2>&1 ]]; then
    echo "ERROR: sqlplus not found in PATH." >&2; exit 1
fi

# ---------- Build connect string ----------
if [[ -n "${TNS_ALIAS}" ]]; then
    CONNECT_TARGET="${TNS_ALIAS}"
else
    if [[ "${LCONNECT_STR}" =~ //* ]]; then
        CONNECT_TARGET="${LCONNECT_STR}"
    else
        CONNECT_TARGET="//${LCONNECT_STR}"
    fi
fi

# ---------- Acquire password ----------
if [[ "${DB_PASS:-}" == "-" ]]; then
    if [[ -t 0 ]]; then
        echo "ERROR: -p - provided but stdin is a TTY." >&2; exit 2
    fi
    IFS= read -r DB_PASS
fi

if [[ "${DB_PASS:-}" == "" ]]; then
    read -s -p "Enter password for ${DB_NAME}: " DB_PASS; echo
fi

# ---------- Build instance filter ----------
# If -i is provided, scope to those instances; otherwise all instances.
if [[ -n "${INST_LIST}" ]]; then
    INST_WHERE="AND inst_id IN (${INST_LIST})"
    INST_WHERE_B="AND s.inst_id IN (${INST_LIST})"
    INST_DISPLAY="${INST_LIST}"
else
    INST_WHERE="AND 1=1"
    INST_WHERE_B="AND 1=1"
    INST_DISPLAY="ALL"
fi

# ---------- Run diagnostic queries ----------
sqlplus -s "${DB_NAME}/${DB_PASS}@${CONNECT_TARGET}" <<EOF

set pages 1000 feedback off verify off heading on linesize 200 termout on

-- ORA-12805 DIAGNOSTIC — Instance(s): ${INST_DISPLAY}

col INST_ID          for 99999    head "INST"
col RESOURCE_NAME    for a20      head "RESOURCE"
col CURRENT_UTILIZATION for 9999999 head "CURRENT"
col MAX_UTILIZATION  for all      head "MAX"
col LIMIT_VALUE      for a15      head "LIMIT"
col PARAM            for a40      head "PARAMETER"
col VALUE            for a20
col PQ_STATUS        for all      head "STATUS"
col LIMIT_SECS       for a20
col PQ_SESSIONS      for 99999    head "PQ_SESS"
col PROGRAM_NAME     for a42      head "PROGRAM"
col QC_SID           for 9999999  head "QC_SID"
col INST             for a10
col SID              for 99990    head "SID"
col SERIAL           for 9999     head "SER#"
col DEGREE           for 9999     head "DOP"
col PQ_ID            for a10      head "PQ_ID"
col STATUS           for a10
col WAITING          for a40      head "WAIT_EVENT"
col USERNAME         for a20
col INACTIVE_SESSIONS for 99999   head "INACTIVE"
col MAX_IDLE_MINS    for 9999.9   head "MAX_IDLE_MIN"

-- ORA-12805 DIAGNOSTIC — Instance(s): ${INST_DISPLAY}

-- 1. Process / session headroom
-- ORA-12805 root cause #1: instance hit the processes or sessions limit and
-- could not spawn a parallel slave. Check if CURRENT is MAX (=> near LIMIT).
prompt
prompt === 1. Process / Session Headroom (GV\$RESOURCE_LIMIT)

SELECT inst_id,
       resource_name,
       current_utilization,
       max_utilization,
       limit_value
FROM   gv\$resource_limit
WHERE  resource_name IN ('processes','sessions')
${INST_WHERE}
ORDER  BY resource_name, inst_id;

-- 2. Parallel server parameters
-- Shows parallel_max_servers (upper bound on PQ slaves), parallel_min_servers,
-- and parallel_adaptive_multi_user. If parallel_max_servers is too high relative
-- to the process limit, PQ can crowd out other sessions.
prompt
prompt === 2. Parallel Server Parameters
prompt

SELECT inst_id,
       name  AS param,
       value
FROM   gv\$parameter
WHERE  name IN (
        'parallel_max_servers',
        'parallel_min_servers',
        'parallel_servers_target',
        'parallel_adaptive_multi_user',
        'parallel_degree_policy',
        'parallel_threads_per_cpu',
        'processes',
        'sessions'
       )
${INST_WHERE}
ORDER  BY name, inst_id;

-- 3. Current PQ slave usage (GV\$PX_PROCESS)
-- Shows how many PQ slaves are currently in use vs available.
prompt
prompt === 3. Current PQ Slave Usage (GV\$PX_PROCESS)
prompt

SELECT inst_id,
       status  AS pq_status,
       COUNT(*) AS cnt
FROM   gv\$px_process
WHERE  1=1
${INST_WHERE}
GROUP  BY inst_id, status
ORDER  BY inst_id, status;

-- 4. Active parallel operations
-- Lists query coordinators (QCs) and how many slaves they are consuming.
-- A single query consuming all available slaves starves other PQ operations.
prompt
prompt === 4. Active Parallel Operations (Query Coordinators)
prompt

SELECT s.inst_id            AS qc_inst,
       s.sid                AS qc_sid,
       s.serial#            AS serial,
       s.username,
       s.program,
       ps.degree,
       (SELECT COUNT(*) FROM gv\$px_session ps
        WHERE  ps.qcinst_id = s.inst_id AND ps.qcsid = s.sid) AS pg_sessions,
FROM   gv\$px_session ps
JOIN   gv\$session s ON s.inst_id = ps.inst_id AND s.sid = ps.qc_sid
WHERE  ps.qcsid = ps.sid          -- QC row only
${INST_WHERE_B}
ORDER  BY ps_sessions DESC;

-- 5. PQ slaves by wait events
-- Shows what PQ slave sessions are waiting on. High counts of
-- "PX Deq: Execution Msg" is normal (idle slaves); look for lock waits,
-- I/O waits, or "PX Deq: Table Q Normal" piled up on one QC.
prompt
prompt === 5. PQ Slave Wait Events
prompt

SELECT s.inst_id,
       s.event,
       COUNT(*) AS waiting
FROM   gv\$px_session ps
JOIN   gv\$session s  ON s.inst_id = ps.inst_id AND s.sid = ps.sid AND s.serial# = ps.serial#
WHERE  ps.qcsid <> ps.sid          -- slaves only, not QC
${INST_WHERE_B}
GROUP  BY s.inst_id, s.event
ORDER  BY s.inst_id, waiting DESC
FETCH  FIRST 15 ROWS ONLY;

-- 6. Non-PQ top consumers (competing for processes)
-- If process headroom is tight, non-PQ sessions may be crowding the instance.
-- Shows top programs (excluding PQ slaves) by session count.
prompt
prompt === 6. Non-PQ Top Consumers (Competing for Processes)
prompt

SELECT inst_id,
       SUBSTR(program, 1, 42) AS program,
       COUNT(*) AS cnt
FROM   gv\$session
WHERE  username IS NOT NULL
AND    sid NOT IN (SELECT sid FROM gv\$px_session WHERE inst_id = gv\$session.inst_id)
${INST_WHERE}
GROUP  BY inst_id, SUBSTR(program, 1, 42)
ORDER  BY inst_id, cnt DESC
FETCH  FIRST 10 ROWS ONLY;

-- 7. Stale inactive sessions eating process slots
-- Leaked / abandoned connections occupy process slots that PQ needs.
prompt
prompt === 7. Stale Inactive Sessions (Eating Process Slots)
prompt

SELECT s.inst_id,
       s.username,
       SUBSTR(s.program, 1, 42) AS program,
       COUNT(*)                  AS inactive_sessions,
       ROUND(MAX(s.last_call_et) / 60, 1) AS max_idle_mins
FROM   gv\$session s
WHERE  s.type   = 'USER'
AND    s.status = 'INACTIVE'
${INST_WHERE_B}
GROUP  BY s.inst_id, s.username, SUBSTR(s.program, 1, 42)
ORDER  BY inactive_sessions DESC, max_idle_mins DESC, s.inst_id
FETCH  FIRST 10 ROWS ONLY;

exit
EOF
