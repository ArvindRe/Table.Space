#!/usr/bin/env bash
# Fetch INSTANCE_NAME from v$instance and MACHINE# for BACKGROUND sessions from v$session.
# Connects as DBSNMP via sqlplus. Supports TNS alias or EZCONNECT.
# Author: Arvind Regukumar (Bengaluru)

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
    get_instance_and_bg_machines.sh [-a <TNS_alias>] [-c <EZCONNECT>] [-u dbsnmp] [-p <password>] [--format table|csv]

Examples:
    # Prompt for password; use TNS alias
    get_instance_and_bg_machines.sh -a PRODR

    # Supply password via stdin (preferred for automation)
    /get_pw.sh DBA_PRODR dbsnmp | ./get_instance_and_bg_machines.sh -a PRODR -p -

    # Use EZCONNECT and CSV output
    ./get_instance_and_bg_machines.sh -c "dbhost:1521/ORCL901" --format csv

Options:
    -a    TNS alias (requires a valid tnsnames.ora entry)
    -c    EZCONNECT string (host:port/service or //host:port/service)
    -u    DB username (default: dbsnmp)
    -p    Password (use '-' to read line from stdin; if omitted, uses env DBSNMP_PASSWORD or prompts securely)
    --format table|csv   Output format (default: table)

Requirements:
    - sqlplus must be in PATH (Oracle client installed).
    - DBSNMP must be granted views access (v$version, v$instance).
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

if [[ -z "${TNS_ALIAS}" && -z "${EZCONNECT_STR}" ]]; then
    echo "ERROR: Provide either -a (TNS alias) or -c <EZCONNECT>, not both." >&2
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

# ---------- Tool checks ----------
if ! command -v sqlplus >/dev/null 2>&1; then
    echo "ERROR: sqlplus not found in PATH. Ensure Oracle client is installed and PATH/ORACLE_HOME are set." >&2
    exit 1
fi

# ---------- Password handling ----------
if [[ "${DB_PASS:-}" == "-" ]]; then
    if [[ -t 0 ]]; then
        echo "ERROR: -p - provided but stdin is a TTY (no piped password)." >&2
        exit 2
    fi
    IFS= read -r DB_PASS
fi

if [[ -z "${DB_PASS:-}" ]]; then
    read -s -rp "Enter password for ${DB_USER}: " DB_PASS
    echo
fi

# ---------- SQLPlus formatting ----------
if [[ "${FORMAT}" == "csv" ]]; then
    SQLPREFIX=$(cat <<'SQL'
set pages 0 feedback off verify off heading on linesize 2000 trimspool on
set markup csv on delimiter ',' quote on
SQL
)
else
    SQLPREFIX=$(cat <<'SQL'
set pages 200 feedback off verify off heading on linesize 2000 trimspool on
col INSTANCE_NAME  for a20
col MACHINE        for a40
SQL
)
fi

# ---------- Execute ----------
# - Get instance_name from v$instance
# - Get distinct machine names where type='BACKGROUND' and not null
sqlplus -s "${DB_USER}/${DB_PASS}@${CONNECT_TARGET}" <<SQLEOF
${SQLPREFIX}
SQL

prompt INSTANCE:
SELECT instance_name AS instance_name
FROM v\$instance;

prompt MACHINES_BACKGROUND:
SELECT DISTINCT machine
FROM v\$session
WHERE type = 'BACKGROUND'
AND machine IS NOT NULL
ORDER BY machine;

exit
SQLEOF
