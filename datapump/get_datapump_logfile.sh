#!/usr/bin/env bash
# Frontend wrapper: resolves the full OS path of a Data Pump log via the Oracle DIRECTORY object.
# Author: Arvind Regukumar
/export/home/oracle/bin/get_pw.sh cx6dapspd dbsnmp | "$(dirname "$0")/run_get_datapump_logfile.sh" "$1" "$2"
