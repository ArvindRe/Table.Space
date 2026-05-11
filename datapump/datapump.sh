#!/usr/bin/bash
# Brought: create_dp_scripts.sh
# Purpose: Create expdp & impdp parfiles + cleanup script inside a ticket folder
# Author: Arvind Regukumar

echo "Enter Ticket Number (example: RJF000123456): "
read TICKET

echo "Enter Oracle DIRECTORY name: "
read DIRECTORY

echo "Enter PARALLEL degree (example: 8): "
read PARALLEL

echo ""
echo "Select job type:"
echo "  1) Table"
echo "  2) Schema"
echo "  3) Full Database"
echo "  4) Tablespace"
echo "  5) Query-Filtered Table"
echo "  6) Metadata-Only  (DB-to-DB, no dumpfile)"
echo "  7) Network Link"
echo "  8) Partitioned Table"
echo ""
read -p "Enter choice [1-8]: " JOB_TYPE

#
# Initialize optional variables
#
TABLES=""
SCHEMAS=""
TABLESPACES=""
REMAP_TS=""
REMAP_SCHEMA=""
INCLUDE_FILTER=""
EXCLUDE_FILTER=""
TABLE_EXISTS_ACTION=""
QUERY_WHERE=""
META_SCOPE=""
NL_SCOPE=""
NETWORK_LINK=""
TTS_MODE=""
IMP_PARALLEL_PT=""

#
# Gather inputs based on job type
#

case $JOB_TYPE in

    1)  # Table
        echo "Enter tables (comma-separated SCHEMA.TABLE): "
        read TABLES
        echo "Enter table_exists_action (skip, append, truncate, replace): "
        read TABLE_EXISTS_ACTION
        echo "Enter remap_table (optional, format OLD_SCHEMA.OLD_TABLE:NEW_SCHEMA.NEW_TABLE): "
        read REMAP_TABLE
        echo "Enter remap_tablespace (optional, format OLD_TS:NEW_TS): "
        read REMAP_TS
        echo "Enter remap_schema (optional, format OLD_SCHEMA:NEW_SCHEMA): "
        read REMAP_SCHEMA
        echo "Enter include filter (optional, e.g. TABLE,INDEX): "
        read INCLUDE_FILTER
        echo "Enter exclude filter (optional, e.g. STATISTICS): "
        read EXCLUDE_FILTER
        ;;

    2)  # Schema
        echo "Enter schemas (comma-separated): "
        read SCHEMAS
        echo "Enter table_exists_action (skip, append, truncate, replace): "
        read TABLE_EXISTS_ACTION
        echo "Enter remap_schema (optional, format OLD_SCHEMA:NEW_SCHEMA): "
        read REMAP_SCHEMA
        echo "Enter remap_tablespace (optional, format OLD_TS:NEW_TS): "
        read REMAP_TS
        echo "Enter include filter (optional, e.g. TABLE,INDEX): "
        read INCLUDE_FILTER
        echo "Enter exclude filter (optional, e.g. STATISTICS): "
        read EXCLUDE_FILTER
        ;;

    3)  # Full Database
        echo "Enter table_exists_action (skip, append, truncate, replace): "
        read TABLE_EXISTS_ACTION
        echo "Enter remap_schema (optional, format OLD_SCHEMA:NEW_SCHEMA): "
        read REMAP_SCHEMA
        echo "Enter remap_tablespace (optional, format OLD_TS:NEW_TS): "
        read REMAP_TS
        echo "Enter exclude filter (optional, e.g. STATISTICS): "
        read EXCLUDE_FILTER
        ;;

    4)  # Tablespace
        echo "Enter tablespaces (comma-separated): "
        read TABLESPACES
        echo "Enable Transportable Tablespace (TTS) mode? (y/n): "
        read TTS_MODE
        echo "Enter remap_tablespace (optional, format OLD_TS:NEW_TS): "
        read REMAP_TS
        ;;

    5)  # Query-Filtered Table
        echo "Enter table (SCHEMA.TABLE): "
        read TABLES
        echo "Enter WHERE clause (without the WHERE keyword, e.g. date_col > SYSDATE-365): "
        read QUERY_WHERE
        echo "Enter table_exists_action (skip, append, truncate, replace): "
        read TABLE_EXISTS_ACTION
        echo "Enter remap_schema (optional, format OLD_SCHEMA:NEW_SCHEMA): "
        read REMAP_SCHEMA
        echo "Enter remap_tablespace (optional, format OLD_TS:NEW_TS): "
        read REMAP_TS
        ;;

    6)  # Metadata-Only
        echo "Select metadata scope:"
        echo "  1) Table"
        echo "  2) Schema"
        echo "  3) Full Database"
        read -p "Enter choice [1-3]: " META_SCOPE
        case $META_SCOPE in
            1)
                echo "Enter tables (comma-separated SCHEMA.TABLE): "
                read TABLES
                ;;
            2)
                echo "Enter schemas (comma-separated): "
                read SCHEMAS
                ;;
            3) ;;
            *)
                echo "Invalid metadata scope. Exiting."
                exit 1
                ;;
        esac
        echo "Enter include filter (optional, e.g. TABLE,INDEX,SEQUENCE): "
        read INCLUDE_FILTER
        echo "Enter exclude filter (optional, e.g. STATISTICS,GRANT): "
        read EXCLUDE_FILTER
        ;;

    7)  # Network Link
        echo "Enter DB link name: "
        read NETWORK_LINK
        echo "Select import scope:"
        echo "  1) Table"
        echo "  2) Schema"
        echo "  3) Full Database"
        read -p "Enter choice [1-3]: " NL_SCOPE
        case $NL_SCOPE in
            1)
                echo "Enter tables (comma-separated SCHEMA.TABLE): "
                read TABLES
                ;;
            2)
                echo "Enter schemas (comma-separated): "
                read SCHEMAS
                ;;
            3) ;;
            *)
                echo "Invalid scope. Exiting."
                exit 1
                ;;
        esac
        echo "Enter table_exists_action (skip, append, truncate, replace): "
        read TABLE_EXISTS_ACTION
        echo "Enter remap_schema (optional, format OLD_SCHEMA:NEW_SCHEMA): "
        read REMAP_SCHEMA
        echo "Enter remap_tablespace (optional, format OLD_TS:NEW_TS): "
        read REMAP_TS
        ;;

    8)  # Partitioned Table
        echo "Enter tables (comma-separated SCHEMA.TABLE): "
        read TABLES
        echo "Enter remap_schema (optional, format OLD_SCHEMA:NEW_SCHEMA): "
        read REMAP_SCHEMA
        echo "Enter remap_tablespace (optional, comma-separated OLD_TS:NEW_TS pairs): "
        read REMAP_TS
        echo "Enter PARALLEL degree for impdp (recommended: 42 for index rebuilds): "
        read IMP_PARALLEL_PT
        ;;

    *)
        echo "Invalid job type. Exiting."
        exit 1
        ;;
esac

#
# Helper: return the scope parameter line for parfiles
#
get_scope_param() {
    case $JOB_TYPE in
        1|5) echo "tables=${TABLES}" ;;
        2)   echo "schemas=${SCHEMAS}" ;;
        3)   echo "full=Y" ;;
        4)
            if [[ "$TTS_MODE" == "y" ]] || [[ "$TTS_MODE" == "Y" ]]; then
                echo "transport_tablespaces=${TABLESPACES}"
            else
                echo "tablespaces=${TABLESPACES}"
            fi
            ;;
        6)
            case $META_SCOPE in
                1) echo "tables=${TABLES}" ;;
                2) echo "schemas=${SCHEMAS}" ;;
                3) echo "full=Y" ;;
            esac
            ;;
        7)
            case $NL_SCOPE in
                1) echo "tables=${TABLES}" ;;
                2) echo "schemas=${SCHEMAS}" ;;
                3) echo "full=Y" ;;
            esac
            ;;
        8) echo "tables=${TABLES}" ;;
    esac
}

#
# Create ticket folder
#
mkdir -p "$TICKET"
cd "$TICKET"

DUMPFILE="expdp_${TICKET}_%U.dmp"
DUMPFILE_BKP="expdp_${TICKET}_BKP_%U.dmp"

#
# EXPDP PARFILE (not applicable for network link)
#
if [[ $JOB_TYPE -ne 7 ]]; then
    EXPFILE="expdp_${TICKET}.par"
    LOGFILE="expdp_${TICKET}.log"
    EXP_JOBNAME="expdp_${TICKET}"

    {
        echo "$(get_scope_param)"
        echo "directory=${DIRECTORY}"
        echo "dumpfile=${DUMPFILE}"
        echo "logfile=${LOGFILE}"
        echo "parallel=${PARALLEL}"
        echo "job_name=${EXP_JOBNAME}"
        echo "metrics=Y"
        echo "logtime=ALL"
        [[ $JOB_TYPE -eq 5 ]] && echo "query=${TABLES}:\"WHERE ${QUERY_WHERE}\""
        [[ $JOB_TYPE -eq 6 ]] && echo "content=METADATA_ONLY"
        [[ $JOB_TYPE -eq 8 ]] && echo "compression=DATA_ONLY"
        # compression=ALL for data exports; not metadata-only (6), not partition-data-only (8), not TTS
        if [[ $JOB_TYPE -ne 6 && $JOB_TYPE -ne 8 && "$TTS_MODE" != "y" && "$TTS_MODE" != "Y" ]]; then
            echo "compression=ALL"
        fi
        # compression_algorithm for all data exports that produce a dumpfile (not metadata-only, not TTS)
        if [[ $JOB_TYPE -ne 6 && "$TTS_MODE" != "y" && "$TTS_MODE" != "Y" ]]; then
            echo "compression_algorithm=MEDIUM"
        fi
        [[ "$TTS_MODE" == "y" || "$TTS_MODE" == "Y" ]] && echo "transport_full_check=Y"
        echo "cluster=N"
        # Always exclude statistics from data exports — re-gather on target after import
        [[ $JOB_TYPE -ne 6 ]] && echo "exclude=STATISTICS"
        [[ -n "$INCLUDE_FILTER" ]] && echo "include=${INCLUDE_FILTER}"
        [[ -n "$EXCLUDE_FILTER" ]] && echo "exclude=${EXCLUDE_FILTER}"
    } > "$EXPFILE"

    #
    # EXPDP BKP PARFILE
    #
    EXPFILE_BKP="expdp_${TICKET}_BKP.par"
    LOGFILE_BKP="expdp_${TICKET}_BKP.log"
    EXP_BKP_JOBNAME="expdp_${TICKET}_BKP"

    {
        echo "job_name=${EXP_BKP_JOBNAME}"
        echo "$(get_scope_param)"
        echo "directory=${DIRECTORY}"
        [[ $JOB_TYPE -ne 7 ]] && echo "dumpfile=${DUMPFILE_BKP}"
        echo "logfile=${LOGFILE_BKP}"
        echo "parallel=${PARALLEL}"
        echo "metrics=Y"
        echo "logtime=ALL"
        [[ $JOB_TYPE -eq 5 ]] && echo "query=${TABLES}:\"WHERE ${QUERY_WHERE}\""
        [[ $JOB_TYPE -eq 6 ]] && echo "content=METADATA_ONLY"
        [[ $JOB_TYPE -eq 8 ]] && echo "compression=DATA_ONLY"
        if [[ $JOB_TYPE -ne 6 && $JOB_TYPE -ne 8 && "$TTS_MODE" != "y" && "$TTS_MODE" != "Y" ]]; then
            echo "compression=ALL"
        fi
        if [[ $JOB_TYPE -ne 6 && "$TTS_MODE" != "y" && "$TTS_MODE" != "Y" ]]; then
            echo "compression_algorithm=MEDIUM"
        fi
        [[ "$TTS_MODE" == "y" || "$TTS_MODE" == "Y" ]] && echo "transport_full_check=Y"
        echo "cluster=N"
        [[ $JOB_TYPE -ne 6 ]] && echo "exclude=STATISTICS"
        [[ -n "$INCLUDE_FILTER" ]] && echo "include=${INCLUDE_FILTER}"
        [[ -n "$EXCLUDE_FILTER" ]] && echo "exclude=${EXCLUDE_FILTER}"
    } > "$EXPFILE_BKP"
fi

#
# IMPDP PARFILE
#
IMPFILE="impdp_${TICKET}.par"
IMPLOG="impdp_${TICKET}.log"
IMP_JOBNAME="impdp_${TICKET}"

# Flag: data import = not metadata-only (6) and not TTS tablespace (4+TTS)
IS_DATA_IMP=1
[[ $JOB_TYPE -eq 6 ]] && IS_DATA_IMP=0
if [[ $JOB_TYPE -eq 4 ]] && [[ "$TTS_MODE" == "y" || "$TTS_MODE" == "Y" ]]; then IS_DATA_IMP=0; fi

# Parallel degree reference for post-import index rebuild comments
PARALLEL_REF="${PARALLEL}"
[[ $JOB_TYPE -eq 8 ]] && PARALLEL_REF="${IMP_PARALLEL_PT}"

{
    if [[ $IS_DATA_IMP -eq 1 ]]; then
        echo "#"
        echo "# PRE-IMPORT (run before impdp):"
        echo "#   ALTER SYSTEM SET DB_BLOCK_CHECKING = FALSE SCOPE=BOTH;"
        echo "#   ALTER SYSTEM SET DB_BLOCK_CHECKSUM = FALSE SCOPE=BOTH;"
        echo "#   ALTER DATABASE NO FORCE LOGGING;"
        echo "#"
    fi
    echo "job_name=${IMP_JOBNAME}"
    # TTS impdp uses transport_datafiles instead of a scope selector
    if [[ $JOB_TYPE -eq 4 ]] && [[ "$TTS_MODE" == "y" || "$TTS_MODE" == "Y" ]]; then
        echo "# transport_datafiles=<comma-separated datafile paths after copying to target>"
    else
        echo "$(get_scope_param)"
    fi
    echo "directory=${DIRECTORY}"
    [[ $JOB_TYPE -ne 7 ]] && echo "dumpfile=${DUMPFILE}"
    echo "logfile=${IMPLOG}"
    if [[ $JOB_TYPE -eq 8 ]]; then
        echo "parallel=${IMP_PARALLEL_PT}"
    else
        echo "parallel=${PARALLEL}"
    fi
    [[ $JOB_TYPE -eq 7 ]] && echo "network_link=${NETWORK_LINK}"
    [[ -n "$TABLE_EXISTS_ACTION" ]] && echo "table_exists_action=${TABLE_EXISTS_ACTION}"
    [[ $JOB_TYPE -eq 6 ]] && echo "content=METADATA_ONLY"
    echo "metrics=Y"
    echo "logtime=ALL"
    # Uncomment to suppress redo for direct-path load (large data imports)
    # When enabled: disable force logging pre-import; run VALIDATE CHECK LOGICAL DATABASE after
    [[ $IS_DATA_IMP -eq 1 ]] && echo "# transform=DISABLE_ARCHIVE_LOGGING:Y"
    if [[ $JOB_TYPE -eq 8 ]]; then
        echo "data_options=TRUST_EXISTING_TABLE_PARTITIONS"
        echo "table_exists_action=replace"
        echo "exclude=GRANT,REF_CONSTRAINT,TRIGGER,INDEX,CONSTRAINT"
    elif [[ $IS_DATA_IMP -eq 1 ]]; then
        echo "exclude=GRANT,REF_CONSTRAINT,TRIGGER,INDEX,CONSTRAINT"
    fi
    [[ -n "$REMAP_TABLE"  ]] && echo "remap_table=${REMAP_TABLE}"
    [[ -n "$REMAP_TS"     ]] && echo "remap_tablespace=${REMAP_TS}"
    [[ -n "$REMAP_SCHEMA" ]] && echo "remap_schema=${REMAP_SCHEMA}"
    [[ -n "$INCLUDE_FILTER" ]] && echo "include=${INCLUDE_FILTER}"
    [[ -n "$EXCLUDE_FILTER" ]] && echo "exclude=${EXCLUDE_FILTER}"
    if [[ $IS_DATA_IMP -eq 1 ]]; then
        echo ""
        echo "#"
        echo "# POST-IMPORT (run after impdp completes):"
        echo "# 1. Restore block integrity checking:"
        echo "#    ALTER SYSTEM SET DB_BLOCK_CHECKING = MEDIUM SCOPE=BOTH;"
        echo "#    ALTER SYSTEM SET DB_BLOCK_CHECKSUM = TYPICAL SCOPE=BOTH;"
        echo "# 2. Re-enable force logging:"
        echo "#    ALTER DATABASE FORCE LOGGING;"
        echo "# 3. Validate imported data:"
        echo "#    VALIDATE CHECK LOGICAL DATABASE;"
        echo "# 4. Rebuild indexes in parallel, then reset degree:"
        echo "#    ALTER INDEX <owner>.<index_name> REBUILD PARALLEL ${PARALLEL_REF};"
        echo "#    ALTER INDEX <owner>.<index_name> NOPARALLEL;"
        echo "# 5. Enable constraints (NOVALIDATE skips full-table scan on existing rows):"
        echo "#    ALTER TABLE <owner>.<table_name> ENABLE NOVALIDATE CONSTRAINT <constraint_name>;"
        echo "# 6. Re-enable triggers:"
        echo "#    ALTER TRIGGER <owner>.<trigger_name> ENABLE;"
        echo "# 7. Re-apply grants:"
        echo "#    GRANT <privilege> ON <owner>.<table_name> TO <role_name>;"
        echo "#"
    fi
} > "$IMPFILE"

#
# Summary
#
JOB_LABELS=("" "Table" "Schema" "Full Database" "Tablespace" "Query-Filtered Table" "Metadata-Only" "Network Link" "Partitioned Table")

echo ""
echo "✔ Folder created       : $TICKET"
echo "✔ Job type             : ${JOB_LABELS[$JOB_TYPE]}"
if [[ $JOB_TYPE -ne 7 ]]; then
    echo "✔ EXPDP parfile        : $EXPFILE"
    echo "✔ EXPDP BKP parfile    : $EXPFILE_BKP"
    if [[ "$TTS_MODE" == "y" || "$TTS_MODE" == "Y" ]]; then
        echo "⚠  TTS mode: update transport_datafiles in $IMPFILE before running impdp"
    fi
fi
echo "✔ IMPDP parfile        : $IMPFILE"
echo ""
[[ $JOB_TYPE -eq 7 ]] && echo "ℹ  Network link mode: no dumpfile needed — impdp pulls data directly via DB link '${NETWORK_LINK}'."
[[ $IS_DATA_IMP -eq 1 ]] && echo "ℹ  PRE/POST-IMPORT SQL blocks are included as comments in $IMPFILE — apply on TARGET before and after impdp."
[[ $JOB_TYPE -eq 8 ]] && echo "ℹ  Partitioned table: data_options=TRUST_EXISTING_TABLE_PARTITIONS skips row-level partition validation on load."
echo ""
echo "ℹ  To inspect or clean up dumpfiles after export, use the centralised scripts:"
echo "     get_dumpfiles.sh   <expdp_logfile>   # list dumpfile paths"
echo "     list_dumpfiles.sh  <expdp_logfile>   # ls -lh of dumpfiles"
echo "     remove_dumpfiles_15d.sh <expdp_logfile>  # remove dumpfiles older than 15 days"
echo "   Schedule remove_dumpfiles_15d.sh via cron 16 days after export. Example cron entry:"
echo "     14 05 <SID> <RC> /export/home/oracle/arvind/remove_dumpfiles_15d.sh <FULL_LOG_PATH> >> /export/home/oracle/arvind/remove_dumpfiles_2${TICKET}.log 2>&1 && crontab -l | grep -v remove_dumpfiles_2${TICKET} | crontab -"
echo ""
echo "ℹ  To protect log files from accidental deletion, archive them to a local immutable location:"
echo "     archive_logfile.sh <expdp_or_impdp_logfile>   # copies to ARCHIVE_DIR and applies chattr +i"
echo "     Run this after both expdp and impdp complete."
