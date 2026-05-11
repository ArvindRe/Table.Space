#!/bin/bash
# Test stub for /export/home/oracle/bin/get_pw.sh
# Deploy to: /export/home/oracle/bin/get_pw.sh on the Oracle database server
# Author: Arvind Regukumar
#
# Usage: get_pw.sh <DB_NAME> <username>
# Prints the password for the given user to stdout.
# The real script fetches from a credential store; this stub hardcodes test passwords.

DB_NAME="${1:-}"
USERNAME="${2:-dbsnmp}"

case "${USERNAME,,}" in
    dbsnmp)      echo 'DBsnmp123' ;;
    system)      echo 'SentinelDBA1' ;;
    aregukumar)  echo 'SentinelDBA1' ;;
    dptest)      echo 'DPTest123' ;;
    *)           echo "ERROR: no password configured for user '${USERNAME}'" >&2; exit 1 ;;
esac
