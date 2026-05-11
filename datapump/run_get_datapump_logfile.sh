#!/usr/bin/env bash
#
# get_dp_logfile.sh
# Connects as DBSNMP and resolves the full Data Pump log file path from a parfile.
# Author: Arvind Regukumar
#
# Usage: ./get_dp_logfile.sh <db_service_or_tns> <parfile_path>
#
set -euo pipefail

# ---------- Args ----------
if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <db_service_or_tns> <parfile_path>"
    echo "  db_service_or_tns : DB service or TNS alias to connect with sqlplus"
    echo "  parfile_path      : full path to the Data Pump parameter file (.par)"
    exit 1
fi

DB_NAME="$1"
PARFILE="$2"

# ---------- Validate parfile ----------
if [[ ! -f "$PARFILE" ]]; then
    echo "ERROR: Parfile not found: $PARFILE"
    exit 2
fi

# ---------- Password prompt ----------
read -s -rp "Enter DBSNMP password for database '${DB_NAME}': " DBSNMP_PASS
echo

# ---------- Helpers ----------
trim() { sed 's/^[[:space:]]*//;s/[[:space:]]*$//' ; }
strip_quotes() { sed -E "s/^['\"]([^'\"]*)['\"]$/\1/" ; }

# ---------- Extract LOGFILE and DIRECTORY (ignore commented lines) ----------
# Accept patterns like:
#   LOGFILE=abc.log
#   logfile = "abc_EXP.log"
#   DIRECTORY = DATA_PUMP_DIR
# Ignore lines starting with # or -- (after optional leading spaces).

LOGFILE_VAL=$(
    grep -i "^[[:space:]]*LOGFILE[[:space:]]*=" "$PARFILE" \
    | grep -vE "^[[:space:]]*#|^[[:space:]]*--" \
    | head -1 \
    | sed -E "s/^[[:space:]]*[Ll][Oo][Gg][Ff][Ii][Ll][Ee][[:space:]]*=[[:space:]]*//" \
    | strip_quotes
)

DIRECTORY_VAL=$(
    grep -i "^[[:space:]]*DIRECTORY[[:space:]]*=" "$PARFILE" \
    | grep -vE "^[[:space:]]*#|^[[:space:]]*--" \
    | head -1 \
    | sed -E "s/^[[:space:]]*[Dd][Ii][Rr][Ee][Cc][Tt][Oo][Rr][Yy][[:space:]]*=[[:space:]]*//" \
    | sed -E "s/^[[:space:]]*[Dd][Ii][Rr][Ee][Cc][Tt][Oo][Rr][Yy][[:space:]]*=[[:space:]]*//" \
    | sed -E "s/^[[:space:]]*[Dd][Ii][Rr][Ee][Cc][Tt][Oo][Rr][Yy][[:space:]]*=[[:space:]]*//" \
    | strip_quotes
)

if [[ -z "${LOGFILE_VAL}" ]]; then
    echo "ERROR: LOGFILE entry not found in parfile: $PARFILE"
    exit 2
fi
if [[ -z "${DIRECTORY_VAL}" ]]; then
    echo "ERROR: DIRECTORY entry not found in parfile: $PARFILE"
    exit 2
fi

# Some exports quote the directory name like 'DATA_PUMP_DIR' — remove quotes if any.
DIRECTORY_VAL="${DIRECTORY_VAL//\'/}"
DIRECTORY_VAL="${DIRECTORY_VAL//\"/}"
DIRECTORY_VAL="${DIRECTORY_VAL//\'/}"
DIRECTORY_VAL="${DIRECTORY_VAL//\'/}"

echo
echo "Parfile values detected."
echo "  DIRECTORY : ${DIRECTORY_VAL}"
echo "  LOGFILE   : ${LOGFILE_VAL}"
echo
echo "Querying Oracle directory path from database '${DB_NAME}' ..."

# ---------- SQL: resolve directory path via DBA_DIRECTORIES ----------
SQL_OUTPUT=$(
    sqlplus -s "dbsnmp/${DBSNMP_PASS}@${DB_NAME}" 2>&1 <<SQL
set pages 0 feedback off verify off heading off echo off trimspool on lines 32767
var v_dir varchar2(128)
exec :v_dir := UPPER('${DIRECTORY_VAL}');
select directory_path from dba_directories where directory_name = :v_dir;
exit
/
SQL
)

# If sqlplus printed ORA-/SP2- errors, show and fail
if echo "${SQL_OUTPUT}" | grep -Eq "^[[:space:]]*(ORA-|SP2-)\d+"; then
    echo "ERROR: Oracle returned an error:"
    echo "${SQL_OUTPUT}"
    exit 4
fi

# Extract first non-empty, non-banner line
DIRECTORY_PATH=$(
    echo "${SQL_OUTPUT}" | awk 'NF{print; exit}' | trim
)

if [[ -z "${DIRECTORY_PATH}" ]]; then
    echo "ERROR: Directory object '${DIRECTORY_VAL}' not found in DBA_DIRECTORIES."
    echo "       Verify the directory name, PDB service, and that DBSNMP has privileges."
    echo "       Needs SELECT_CATALOG_ROLE or SELECT on SYS.DBA_DIRECTORIES."
    exit 5
fi

# ---------- Build and display full path ----------
FULL_LOG_PATH="${DIRECTORY_PATH}/${LOGFILE_VAL}"

cat <<INFO

  Database      : ${DB_NAME}
  Directory Obj : ${DIRECTORY_VAL}
  OS Path       : ${DIRECTORY_PATH}
  Log File      : ${LOGFILE_VAL}

  FULL_LOG_PATH : ${FULL_LOG_PATH}

INFO
