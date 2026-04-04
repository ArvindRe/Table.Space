#!/usr/bin/env bash
# Frontend wrapper: report database size (data files + temp files) as DBSNMP.
# Usage:  ./get_db_size.sh <DB_NAME>
# Author: Arvind Regukumar

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
/export/home/oracle/bin/get_pw.sh cx6dapspd dbsnmp | "${SCRIPT_DIR}/run_get_db_size.sh" -a "$1" -p -
