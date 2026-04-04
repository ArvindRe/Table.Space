#!/bin/bash
/export/home/oracle/bin/get_pw.sh cx6dapspd dbsnmp | ./run_get_db_host.sh -u dbsnmp -a $1 -p -
