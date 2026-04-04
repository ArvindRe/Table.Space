#!/usr/bin/env bash
# Query gv$session_longops for operations with opname like %TICKETNAME% as DBSNMP.
# Outputs progress, time remaining, start time, etc.
# Author: Arvind Regukumar
set -euo pipefail

# ---------- Defaults / Globals ----------
DB_USER="dbsnmp"
DB_PASS="${DBSNMP_PASSWORD:-}"    # can be provided via env var
TNS_ALIAS=""
LCONNECT_STR=""
TICKET=""
FORMAT="table"    # table|csv

usage() {
    cat <<HELP
Usage:
    ticket_longops.sh -m <TICKETNAME> [-a <TNS_alias>] [-c <LCONNECT_STR>] [-u dbsnmp]
                      [-y <password>] [-p <password>] [--format table|csv]

Examples:
    # Omit the password, use TNS alias; search for operations containing 'INC1234567'
    ./ticket_longops.sh -m INC1234567 -a PRODR

    # Use LCONNECT and CSV output
    ./ticket_longops.sh -m INC1234567 -c "dbhost.example.com:1521/ORCL901" --format csv

    # Pipe password from helper
    /get_pw.sh DBA_PRODR dbsnmp | ./ticket_longops.sh -m INC123 -a PRODR -p -

Options:
    -m    The substring to match in OPNAME (case-insensitive LIKE '%TICKET%')
    -a    TNS alias (must exist in tnsnames.ora)
    -c    LCONNECT_STR (host:port/service or //host:port/service)
    -u    DB username (default: dbsnmp)
    -p    Password (to be read from stdin if omitted; uses DBSNMP_PASSWORD or prompts securely)
    --format table|csv   Output format (default: table)
    -h    Help

Notes:
    - Requires: sqlplus in PATH.
    - DBSNMP must have privileges to read gv$session and gv$session_longops (usually true).
HELP
}

# ---------- Parse arguments ----------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -m) TICKET="${2:-}";         shift 2 ;;
        -a) TNS_ALIAS="${2:-}";      shift 2 ;;
        -c) LCONNECT_STR="${2:-}";   shift 2 ;;
        -u) DB_USER="${2:-}";        shift 2 ;;
        -p) DB_PASS="${2:-}";        shift 2 ;;
        --format) FORMAT="${2:-}";   shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
    esac
done

# ---------- Validate inputs ----------
if [[ -z "${TICKET}" ]]; then
    echo "ERROR: -m <TICKETNAME> is required." >&2
    usage; exit 2
fi

if [[ -z "${TNS_ALIAS}" ]] && [[ -z "${LCONNECT_STR}" ]]; then
    echo "ERROR: Provide either -a (TNS alias) or -c <LCONNECT_STR>, not both." >&2
    exit 2
fi

if [[ -n "${TNS_ALIAS}" ]] && [[ -n "${LCONNECT_STR}" ]]; then
    echo "ERROR: Provide -a (TNS alias) or -c <LCONNECT_STR>." >&2
    usage; exit 2
fi

if [[ "${FORMAT}" != "table" ]] && [[ "${FORMAT}" != "csv" ]]; then
    echo "ERROR: --format must be 'table' or 'csv'." >&2
    exit 2
fi

# ---------- Build connect target ----------
CONNECT_TARGET=""
if [[ -n "${TNS_ALIAS}" ]]; then
    CONNECT_TARGET="${TNS_ALIAS}"
else
    if [[ "${LCONNECT_STR}" == //* ]]; then
        CONNECT_TARGET="${LCONNECT_STR}"
    else
        CONNECT_TARGET="//${LCONNECT_STR}"
    fi
fi

# ---------- Tool check ----------
if ! command -v sqlplus >/dev/null 2>&1; then
    echo "ERROR: sqlplus not found in PATH. Ensure Oracle client is installed and PATH/ORACLE_HOME are set." >&2
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

# ---------- Run query ----------
# Notes:
#  - Make LIKE match case-insensitive with UPPER()
#  - Avoid division by zero (filter totalwork > 0)
#  - Show key columns and progress with SOFAR and TIME_REMAINING (seconds -> HH24:MI:SS approx)
#  - Order by start_time ascending (oldest first)
#
# Columns returned:
#   USERNAME, SID, OPNAME, TARGET, DONE_PCT, TIME_REMAINING_SEC, START_TIME
#
# For table: set column widths; for CSV: set markup csv on.

if [[ "${FORMAT}" == "csv" ]]; then
    SQLPREFIX=$(cat <<'SQL'
set pages 0 feedback off verify off heading on linesize 2000 trimspool on
set markup csv on delimiter ',' quote on
SQL
)
else
    SQLPREFIX=$(cat <<'SQL'
set pages 1000 feedback off verify off heading on linesize 2000 trimspool on
col OPNAME   for a40
col DBNAME   for a20
col TARGET   for a40
col START_TIME for a19
SQL
)
fi

# ---------- Execute ----------
sqlplus -s "${DB_USER}/${DB_PASS}@${CONNECT_TARGET}" <<SQLEOF
${SQLPREFIX}
;

var v_ticket varchar2(4000)
exec :v_ticket := upper('${TICKET}');

-- Do the SYS rows to be RAC-aware. TIME_REMAINING is in seconds;
-- use > SOFAR/100 * NULLIF(TOTALWORK,0), 0 )
SELECT
    a.username,
    a.sid,
    b.opname,
    ROUND(b.sofar/100 / NULLIF(b.totalwork,0), 0) AS "DONE_PCT",
    b.time_remaining AS "TIME_REMAINING_SEC",
    to_char(b.start_time, 'YYYY/MM/DD HH24:MI:SS') AS start_time
FROM gv\$session_longops b
JOIN gv\$session a ON a.sid = b.sid AND a.inst_id = b.inst_id
AND b.totalwork IS NOT NULL
AND upper(b.opname) LIKE '%'||:v_ticket||'%'
ORDER BY start_time ASC;

exit
SQLEOF
