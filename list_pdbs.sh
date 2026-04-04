#!/bin/bash
# Function to run SQL commands and fetch PDB details
get_pdbs() {
    local cdb="$1"
    echo "Checking PDBs in CDB: $cdb"
    sqlplus -s /nolog <<ENDSQL
CONNECT / AS SYSDBA
SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF HEADING OFF ECHO OFF
SHOW PDBS
EXIT
ENDSQL
}

# Main script
echo "Finding all container databases on the Linux server..."
cdbs=$(ps -ef | grep pmon | grep -v ASM| grep -v grep | awk -F'_' '{print $3}')
if [[ ${#cdbs[@]} -eq 0 ]]; then
    echo "No container databases found."
    exit 1
fi

echo "List of container databases:"
echo "${cdbs[@]}"
echo
echo "Collecting PDBs for each CDB..."
for cdb in "${cdbs[@]}"; do
    # Set the Oracle environment for the current CDB
    export ORACLE_SID=$cdb
    oraenv <<< "ORACLE_SID" >/dev/null 2>&1
    # Fetch PDBs for the current CDB
    pdbs=$(get_pdbs "$cdb")
    if [ -z "$pdbs" ]; then
        echo "No PDBs found in CDB: $cdb"
    else
        echo "PDBs in CDB $cdb:"
        echo "$pdbs"
    fi
    echo
done
