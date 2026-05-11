#!/bin/bash
# SSHs to a remote Oracle server and lists all CDBs and PDBs via list_pdbs.sh.
# Author: Arvind Regukumar
# eg. sh fetch_pdbs_dynamic.sh iorce01ldb1qa

scp list_pdbs.sh oracle@$1:/tmp/list_pdbs.sh

ssh $1 sh /tmp/list_pdbs.sh
