#!/bin/bash
# $1 SOURCE
# $2 TNSNAME

/export/home/oracle/bin/get_pw.sh cx6dapspd dbsnmp | ./run_datapump_longops.sh -m $1 -a $2 -p -
