#!/bin/bash
# Frontend wrapper: resolves the CDB instance name and background machine hostname for a given DB.
# Author: Arvind Regukumar
/export/home/oracle/bin/get_pw.sh "$1" dbsnmp | ./run_get_db_host.sh -u dbsnmp -a "$1" -p -
