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
        echo "ERROR: -p - provided but stdin is a TTY. Pipe the password." >&2
        exit 2
    fi
    IFS= read -r DB_PASS
fi

if [[ -z "${DB_PASS:-}" ]]; then
    read -s -rp "Enter password for ${DB_USER}: " DB_PASS
    echo
fi

if ! command -v sqlplus >/dev/null 2>&1; then
    echo "ERROR: sqlplus not found in PATH. Ensure ORACLE_HOME and PATH are set." >&2
    exit 1
fi

# ---------- Run query ----------
if [[ "${FORMAT}" == "csv" ]]; then
    SEP="','"
    sqlplus -s "${DB_USER}/${DB_PASS}@${CONNECT_TARGET}" <<SQLEOF
set pages 0 feedback off verify off heading off linesize 200 trimspool on
set colsep ,

SELECT 'SEGMENT_TYPE,SIZE_GB,SIZE_TB' FROM dual;

SELECT segment_type || ',' || size_gb || ',' || size_tb
FROM (
  SELECT 'DATA' AS segment_type,
         ROUND(SUM(bytes)/1073741824, 2)    AS size_gb,
         ROUND(SUM(bytes)/1099511627776, 4) AS size_tb
  FROM   dba_data_files
  UNION ALL
  SELECT 'TEMP',
         ROUND(SUM(bytes)/1073741824, 2),
         ROUND(SUM(bytes)/1099511627776, 4)
  FROM   dba_temp_files
  UNION ALL
  SELECT 'TOTAL',
         ROUND(( (SELECT SUM(bytes) FROM dba_data_files) +
                 (SELECT SUM(bytes) FROM dba_temp_files) ) / 1073741824, 2),
         ROUND(( (SELECT SUM(bytes) FROM dba_data_files) +
                 (SELECT SUM(bytes) FROM dba_temp_files) ) / 1099511627776, 4)
  FROM   dual
);

exit
SQLEOF
else
    sqlplus -s "${DB_USER}/${DB_PASS}@${CONNECT_TARGET}" <<SQLEOF
set pages 100 feedback off verify off heading on linesize 120 trimspool on

col SEGMENT_TYPE for a10         head "TYPE"
col SIZE_GB      for 999,999.99  head "SIZE_GB"
col SIZE_TB      for 999.9999    head "SIZE_TB"

prompt
prompt === Database Size Report
prompt

SELECT segment_type, size_gb, size_tb
FROM (
  SELECT 'DATA' AS segment_type,
         ROUND(SUM(bytes)/1073741824, 2)    AS size_gb,
         ROUND(SUM(bytes)/1099511627776, 4) AS size_tb,
         1 AS sort_order
  FROM   dba_data_files
  UNION ALL
  SELECT 'TEMP',
         ROUND(SUM(bytes)/1073741824, 2),
         ROUND(SUM(bytes)/1099511627776, 4),
         2
  FROM   dba_temp_files
  UNION ALL
  SELECT 'TOTAL',
         ROUND(( (SELECT SUM(bytes) FROM dba_data_files) +
                 (SELECT SUM(bytes) FROM dba_temp_files) ) / 1073741824, 2),
         ROUND(( (SELECT SUM(bytes) FROM dba_data_files) +
                 (SELECT SUM(bytes) FROM dba_temp_files) ) / 1099511627776, 4),
         3
  FROM   dual
)
ORDER  BY sort_order;

exit
SQLEOF
fi
