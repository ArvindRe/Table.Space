#!/usr/bin/env bash
/export/home/oracle/bin/get_pw.sh cx6dapspd dbsnmp | "$(dirname "$0")/run_get_datapump_logfile.sh" "$1" "$2"
