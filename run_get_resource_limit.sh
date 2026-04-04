#!/usr/bin/env bash
# Query GV$RESOURCE_LIMIT for processes, sessions, and transactions as DBSNMP.
# Then report the top 5 users contributing to each resource.
# Author: Arvind Regukumar

set -euo pipefail

# ---------- Defaults ----------
DB_USER="dbsnmp"
DB_PASS="${DBSNMP_PASSWORD:-}"
TNS_ALIAS=""
EZCONNECT_STR=""
FORMAT="table"    # table|csv

usage() {
    cat <<HELP
Usage:
    run_get_resource_limit.sh [-a <TNS_alias>] [-c <EZCONNECT>] [-u dbsnmp] [-p <password>] [--format table|csv]

Examples:
    # Prompt for password; use TNS alias
    ./run_get_resource_limit.sh -a PRODR

    # Supply password via stdin (preferred for automation)
    /get_pw.sh DBA_PRODR dbsnmp | ./run_get_resource_limit.sh -a PRODR -p -

    # Use EZCONNECT and CSV output
    ./run_get_resource_limit.sh -c "dbhost:1521/ORCL901" --format csv

Options:
    -a    TNS alias (requires a valid tnsnames.ora entry)
    -c    EZCONNECT string (host:port/service or //host:port/service)
    -u    DB username (default: dbsnmp)
    -p    Password (use '-' to read one line from stdin; if omitted, uses env DBSNMP_PASSWORD or prompts securely)
    --format table|csv   Output format (default: table)

Requirements:
    - sqlplus must be in PATH (Oracle client installed).
    - DBSNMP must have SELECT privilege on GV$RESOURCE_LIMIT, GV$SESSION,
      GV$PROCESS, and GV$TRANSACTION (all granted through SELECT_CATALOG_ROLE).
HELP
}

# ---------- Parse args ----------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -a) TNS_ALIAS="${2:-}";        shift 2 ;;
        -c) EZCONNECT_STR="${2:-}";    shift 2 ;;
        -u) DB_USER="${2:-}";          shift 2 ;;
        -p) DB_PASS="${2:-}";          shift 2 ;;
        --format) FORMAT="${2:-}";     shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
    esac
done

# ---------- Validate ----------
if [[ -z "${TNS_ALIAS}" && -z "${EZCONNECT_STR}" ]]; then
    echo "ERROR: Provide either -a (TNS alias) OR -c <EZCONNECT>, not both." >&2
    exit 2
fi

if [[ -n "${TNS_ALIAS}" && -n "${EZCONNECT_STR}" ]]; then
    echo "ERROR: Provide -a (TNS alias) or -c <EZCONNECT>." >&2
    usage; exit 2
fi

if [[ "${FORMAT}" != "table" && "${FORMAT}" != "csv" ]]; then
    echo "ERROR: --format must be 'table' or 'csv'." >&2
    exit 2
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
    echo "ERROR: sqlplus not found in PATH. Ensure ORACLE_HOME and PATH are set." >&2
    exit 1
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
set pages 1000 feedback off verify off heading on linesize 200 trimspool on
col INST_ID              for 99999    head "INST"
col RESOURCE_NAME        for a20      head "RESOURCE_NAME"
col CURRENT_UTILIZATION  for 9999999  head "CURRENT"
col MAX_UTILIZATION      for 9999999  head "MAX/"
col LIMIT_VALUE          for a12      head "LIMIT"
col USERNAME             for a30      head "USERNAME"
col PROCESS_COUNT        for 9999999  head "PROCESSES"
col SESSION_COUNT        for 9999999  head "SESSIONS"
col TXN_COUNT            for 9999999  head "TRANSACTIONS"
SQL
)
fi

# ---------- Run query ----------
sqlplus -s "${DB_USER}/${DB_PASS}@${CONNECT_TARGET}" <<SQLEOF
${SQLPREFIX}
SQL

-- Resource Limits -------------------------------------------------------
prompt
prompt === Resource Limits (processes / sessions / transactions)
prompt

SELECT inst_id,
       resource_name,
       current_utilization,
       max_utilization,
       limit_value
FROM   gv\$resource_limit
WHERE  resource_name IN ('processes','sessions','transactions')
ORDER  BY resource_name, inst_id;

-- Top 5 users by session count ------------------------------------------
prompt
prompt === Top 5 Users by Session Count
prompt

SELECT username, COUNT(*) AS session_count
FROM   gv\$session s
WHERE  username IS NOT NULL
GROUP  BY username
ORDER  BY session_count DESC
FETCH  FIRST 5 ROWS ONLY;

-- Top 5 users by process count ------------------------------------------
prompt
prompt === Top 5 Users by Process Count
prompt

SELECT s.username, COUNT(DISTINCT p.addr) AS process_count
FROM   gv\$process p
JOIN   gv\$session s ON p.addr = s.paddr AND p.inst_id = s.inst_id
WHERE  s.username IS NOT NULL
GROUP  BY s.username
ORDER  BY process_count DESC
FETCH  FIRST 5 ROWS ONLY;

-- Top 5 users by open transaction count --------------------------------
prompt
prompt === Top 5 Users by Open Transaction Count
prompt

SELECT s.username, COUNT(*) AS txn_count
FROM   gv\$transaction t
JOIN   gv\$session s ON t.addr = s.taddr AND t.inst_id = s.inst_id
WHERE  s.username IS NOT NULL
GROUP  BY s.username
ORDER  BY txn_count DESC
FETCH  FIRST 5 ROWS ONLY;

exit
SQLEOF
