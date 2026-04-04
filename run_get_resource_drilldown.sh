#!/usr/bin/env bash
# Root-cause investigation for high-utilisation Oracle RAC instances.
# Invoked by get_resource_limit.sh when processes or sessions exceed the alert
# threshold. Shows session breakdown, wait events, client programs, and blockers.
# Author: Arvind Regukumar

set -euo pipefail

# ---------- Defaults ----------
DB_USER="dbsnmp"
DB_PASS=""
TNS_ALIAS=""
EZCONNECT_STR=""
INST_LIST=""     # comma-separated instance IDs, e.g. "3,4" — set via -i

usage() {
    cat <<HELP
Usage:
    run_get_resource_drilldown.sh [-a <TNS_alias>] [-c <EZCONNECT>] [-i <inst_ids>]
                                  [-u <dbsnmp>] [-p <password>]

Examples:
    # Investigate instances 1 and 4; password via stdin
    /get_pw.sh DBA_PRODR dbsnmp | ./run_get_resource_drilldown.sh -a PRODR -i 1,4 -p -

Options:
    -a    TNS alias
    -c    EZCONNECT string (host:port/service or //host:port/service)
    -i    Comma-separated list of instance IDs to investigate (required)
    -u    DB username (default: dbsnmp)
    -p    Password; use '-' to read one line from stdin

Requirements:
    DBSNMP needs SELECT_CATALOG_ROLE (covers GV$SESSION, GV$PROCESS, GV$TRANSACTION).
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
    echo "ERROR: -i must be a comma-separated list of integers (e.g. 3,4)." >&2; exit 2
fi

if [[ -z "${TNS_ALIAS}" && -z "${EZCONNECT_STR}" ]]; then
    echo "ERROR: Provide either -a (TNS alias) OR -c <EZCONNECT>, not both." >&2; exit 2
fi

if [[ -n "${TNS_ALIAS}" && -n "${EZCONNECT_STR}" ]]; then
    echo "ERROR: Provide -a (TNS alias) or -c <EZCONNECT>." >&2; usage; exit 2
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

# ---------- Run investigation queries ----------
# INST_LIST is validated integers-only above: safe to interpolate into SQL IN clause.
sqlplus -s "${DB_USER}/${DB_PASS}@${CONNECT_TARGET}" <<SQLEOF
set pages 1000 feedback off verify off heading on linesize 200 trimspool on

col INST_ID          for 99999    head "INST"
col USERNAME         for a20      head "USERNAME"
col STATUS           for a10      head "STATUS"
col SESSION_COUNT    for 99999999 head "SESSIONS"
col EVENT            for a40      head "WAIT_EVENT"
col WAIT_COUNT       for 99999999 head "WAIT_COUNT"
col WAITING          for a40      head "WAIT_EVENT"
col PROGRAM          for 99999999 head "WAIT_EVENT"
col PROGRAM          for a42      head "PROG"
col MACHINE          for a40      head "MACHINE"
col MODULE           for a30      head "MODULE"
col BLOCKER_SID      for 9999     head "BLOCKER_SID"
col BLOCKER_INST     for 9999     head "BLOCKER_INST"
col BLOCKER_USER     for a20      head "BLOCKER"
col BLOCKED_OVER     for a20      head "BLOCKED_BY"
col MACHINE          for a42      head "MACHINE"
col MODULE           for a32      head "MODULE"
col USERNAME         for a25      head "USERNAME"
col CNT              for 99999999 head "SESSIONS"
col OLDEST_LOGON     for a20      head "OLDEST_LOGON"
col NEWEST_LOGON     for a20      head "NEWEST_LOGON"
col INACTIVE_SESSIONS for 9999999 head "INACTIVE"
col MAX_IDLE_MINS    for 9999.9   head "MAX_IDLE_MIN"

-- 1. Session breakdown by username and status
-- ACTIVE vs INACTIVE split helps distinguish live load from abandoned connections.
prompt
prompt === Instance(s) ${INST_LIST} — Sessions by Username and Status
prompt

SELECT inst_id,
       username,
       status,
       COUNT(*) AS session_count
FROM   gv\$session
WHERE  inst_id IN (${INST_LIST})
AND    username IS NOT NULL
GROUP  BY inst_id, username, status
ORDER  BY inst_id, session_count DESC
FETCH  FIRST 20 ROWS ONLY;

-- 2. Top non-idle wait events
-- High counts of lock, latch, or I/O waits point to contention drivers.
prompt
prompt === Instance(s) ${INST_LIST} — Top Wait Events (Active Sessions, Non-Idle)
prompt

SELECT  inst_id,
        event,
        COUNT(*) AS waiting
FROM    gv\$session
WHERE   inst_id IN (${INST_LIST})
AND     username IS NOT NULL
AND     status = 'ACTIVE'
AND     wait_class <> 'Idle'
GROUP   BY inst_id, event
ORDER   BY waiting DESC
FETCH   FIRST 15 ROWS ONLY;

-- 3. Top client programs
-- Identifies which application tiers or tools are monopolising connections.
prompt
prompt === Instance(s) ${INST_LIST} — Top Client Programs
prompt

SELECT inst_id,
       SUBSTR(program, 1, 42) AS program,
       COUNT(*) AS prog_sessions
FROM   gv\$session
WHERE  inst_id IN (${INST_LIST})
AND    username IS NOT NULL
GROUP  BY inst_id, SUBSTR(program, 1, 42)
ORDER  BY inst_id, prog_sessions DESC
FETCH  FIRST 15 ROWS ONLY;

-- 4. Machine / program / module / user breakdown
-- Narrows top programs to the exact source machine and module so the owning
-- application team can be contacted.
prompt
prompt === Instance(s) ${INST_LIST} — Top Sessions by Machine / Program / Module / User
prompt

SELECT machine,
       SUBSTR(program, 1, 42) AS program,
       module,
       username,
       COUNT(*) AS cnt
FROM   gv\$session
WHERE  inst_id IN (${INST_LIST})
AND    username IS NOT NULL
GROUP  BY machine, SUBSTR(program, 1, 42), module, username
ORDER  BY cnt DESC
FETCH  FIRST 10 ROWS ONLY;

-- 5. Inactive session age — connection pool leak indicator
-- Sessions INACTIVE for many minutes (especially JDBC with action=null) are
-- almost always un-returned connection-pool connections or abandoned clients.
-- oldest_logon far in the past confirms the pool is not recycling.
prompt
prompt === Instance(s) ${INST_LIST} — Stale Inactive Sessions (Idle Time)
prompt

SELECT s.inst_id,
       s.username,
       SUBSTR(s.program, 1, 42) AS program,
       s.module,
       COUNT(*)                   AS inactive_sessions,
       ROUND(MAX(s.last_call_et) / 60, 1) AS max_idle_mins
FROM   gv\$session s
WHERE  s.inst_id IN (${INST_LIST})
AND    s.type   = 'USER'
AND    s.status = 'INACTIVE'
GROUP  BY s.inst_id, s.username, SUBSTR(s.program, 1, 42), s.module
ORDER  BY max_idle_mins DESC, s.inst_id
FETCH  FIRST 10 ROWS ONLY;

-- 6. JDBC Thin Client connection pool leak check
-- Detects abandoned JDBC connections: action IS NULL means the app never set
-- a module action (i.e. idle/leaked). oldest_logon far in the past confirms
-- the pool is not recycling those connections.
prompt
prompt === Instance(s) ${INST_LIST} — JDBC Thin Client Leak Check (action IS NULL)
prompt

SELECT program,
       module,
       username,
       TO_CHAR(MIN(logon_time), 'DD-MON-YYYY HH24:MI') AS oldest_logon,
       TO_CHAR(MAX(logon_time), 'DD-MON-YYYY HH24:MI') AS newest_logon,
       COUNT(*)                                          AS cnt
FROM   gv\$session
WHERE  inst_id IN (${INST_LIST})
AND    program = 'JDBC Thin Client'
AND    module  = 'JDBC Thin Client'
AND    action  IS NULL
GROUP  BY program, module, username
ORDER  BY MIN(logon_time)
FETCH  FIRST 10 ROWS ONLY;

-- 7. Blocking sessions
-- Shows sessions on the flagged instances that are blocking others, plus
-- cross-instance blockers whose victims are on a flagged instance.
prompt
prompt === Instance(s) ${INST_LIST} — Blocking Sessions
prompt

SELECT b.inst_id        AS blocker_inst,
       b.sid            AS blocker_sid,
       b.username       AS blocker_user,
       COUNT(w.sid)     AS blocked_count
FROM   gv\$session b
JOIN   gv\$session w
       ON  w.blocking_instance = b.inst_id
       AND w.blocking_session  = b.sid
WHERE  b.inst_id IN (${INST_LIST})
OR     w.inst_id IN (${INST_LIST})
GROUP  BY b.inst_id, b.sid, b.username
ORDER  BY b.inst_id, b.sid, b.username
ORDER  BY blocked_count DESC;

exit
SQLEOF
