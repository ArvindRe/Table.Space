#!/usr/bin/env bash
# Query DBA_DATA_FILES and DBA_TEMP_FILES to report database size as DBSNMP.
# Outputs DATA, TEMP, and TOTAL sizes in GB and TB.
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
    run_get_db_size.sh [-a <TNS_alias>] [-c <EZCONNECT>] [-u dbsnmp] [-p <password>] [--format table|csv]

Examples:
    # Prompt for password; use TNS alias
    run_get_db_size.sh -a PRODR

    # Supply password via stdin (preferred for automation)
    /get_pw_db_PRODR dbsnmp | ./run_get_db_size.sh -a PRODR -p -

    # Use EZCONNECT and CSV output
    run_get_db_size.sh -c "dbhost:1521/ORCL901" --format csv

Options:
    -a    TNS alias (requires a valid tnsnames.ora entry)
    -c    EZCONNECT string (host:port/service or //host:port/service)
    -u    DB username (default: dbsnmp)
    -p    Password (use '-' to read one line from stdin; if omitted, uses env DBSNMP_PASSWORD or prompts securely)
    --format table|csv   Output format (default: table)

Requirements:
    - sqlplus must be in PATH (Oracle client installed).
    - DBSNMP must have SELECT privilege on DBA_DATA_FILES and DBA_TEMP_FILES
      (granted through SELECT_CATALOG_ROLE).
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
