#!/usr/bin/env bash
#
# datapump_workflow.sh
# Author: Arvind Regukumar
#
# Interactive end-to-end wrapper for the Oracle Data Pump script suite.
# Runs every step in the correct order with prompts to Proceed, Skip, or Exit.
# Collects required inputs upfront and passes them to each underlying script.
#
# Steps:
#   1. Generate parfiles          (datapump.sh)
#   2. Run SOURCE export          (expdp)
#   3. Resolve source log path    (get_datapump_logfile.sh)
#   4. Inspect dumpfiles          (list_dumpfiles.sh)
#   5. Run TARGET backup export   (expdp BKP)
#   6. Run TARGET import          (impdp)
#   7. Archive log files          (archive_logfile.sh)
#   8. Schedule dumpfile cleanup  (schedule_cleanup_cron_16d.sh)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- Oracle environment ----------
# Sources the oracle user's login profile to ensure ORACLE_HOME, PATH (expdp,
# impdp, sqlplus) and TNS_ADMIN are available regardless of how this script
# is invoked (sudo, batch, call, nohup, cron, etc.).
for _profile in ~/.bash_profile ~/.bashrc /etc/oraenv; do
    [[ -f "$_profile" ]] && source "$_profile" && break
done

# If oraenv is available and ORACLE_SID is set, run it to complete the env.
if command -v oraenv >/dev/null 2>&1 && [[ -n "${ORACLE_SID:-}" ]]; then
    ORAENV_ASK=NO oraenv >/dev/null 2>&1 || true
fi

# Verify Oracle tools are reachable before going any further.
if ! command -v expdp >/dev/null 2>&1 || ! command -v sqlplus >/dev/null 2>&1; then
    echo ""
    printf "${YELLOW}⚠  Oracle tools (expdp/impdp/sqlplus) not found in PATH.${RESET}\n"
    echo "   Ensure ORACLE_HOME and PATH are set, or source your Oracle profile first."
    echo "   source ~/.bash_profile"
    echo "   ORACLE_SID=<SID>  ORACLE_PATH=<SID>   oraenv"
    echo ""
    read -rp "   Continue anyway? (y/N) : " _cont
    [[ "${_cont,,}" == "y" ]] || exit 1
fi

unset _profile _cont

# ---------- Colour helpers ----------
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m';  RESET='\033[0m'

hdr()   { printf "\n${CYAN}${BOLD} STEP %s: ${RESET}\n" "$*"; }
ok()    { printf "${BOLD}  [DONE] STEP %s — %s${RESET}\n" "$1" "$2"; sep; }
sk()    { printf "${GREEN}  ✔ %s${RESET}\n" "$*"; }
warn()  { printf "${YELLOW}  ⚠  %s${RESET}\n" "$*"; }
sep()   { printf " %s\n" ""; }
info()  { printf "${BOLD}  %s${RESET}\n" "$*"; }

# ---------- Gate: a step; returns 0=proceed, 1=skip ----------
ask_step() {
    local desc="$1"
    while true; do
        read -rp "$(printf "${BOLD}  ▶ [P]roceed  [S]kip  [E]xit  — ${RESET}")" choice || exit 0
        case "${choice,,}" in
            p|proceed) return 0 ;;
            s|skip)    warn "Skipping."; return 1 ;;
            e|exit)    printf "${YELLOW}Exiting workflow.${RESET}\n\n"; exit 0 ;;
            *) warn "Enter P, S, or E." ;;
        esac
    done
}

# ---------- Prompts with a default value ----------
prompt_default() {
    local msg="$1" default="$2" var_name="$3"
    read -rp "  ${msg} [${default}]: " val
    printf -v "$var_name" '%s' "${val:-${default}}"
}

# ---------- Prompts required (loops until non-empty) ----------
prompt_required() {
    local msg="$1" var_name="$2"
    local val=""
    while [[ -z "$val" ]]; do
        read -rp "  ${msg}: " val
        [[ -z "$val" ]] && warn "This field is required."
    done
    printf -v "$var_name" '%s' "$val"
}

# ---------- Log a completed job to rj_dba_datapump_log ----------
# Usage: dp_log_entry <db> <user> <pass> <EXP|IMP|EXP_BKP> <logfile> <parfile> <start_ts> <end_ts> <exit_code>
dp_log_entry() {
    local db="$1" db_user="$2" db_pass="$3"
    local operation="$4" logfile="$5" parfile="$6"
    local start_ts="$7" end_ts="$8" job_no="$9"
    local status="SUCCESS"
    [[ $job_no -ne 0 ]] && status="FAILED"

    # ---------- Extract fields from parfile ----------
    local parfile_contents="" job_name="" parallel_degree="" dumpfile=""
    if [[ -f "${parfile}" ]]; then
        # Full parfile comments (comments stripped, single-quotes escaped for SQL)
        parfile_contents=$(grep -v "^[[:space:]]*#" "${parfile}" | tr "'" '"' | sed "s/'/\'\'/g")

        job_name=$(grep -i "^[[:space:]]*job_name[[:space:]]*=" "${parfile}" \
            | grep -v "^[[:space:]]*#" | head -1 \
            | sed -E "s/.*=[[:space:]]*//" | tr -d "'\"")

        parallel_degree=$(grep -i "^[[:space:]]*parallel[[:space:]]*=" "${parfile}" \
            | grep -v "^[[:space:]]*#" | head -1 \
            | sed -E "s/.*=[[:space:]]*//" | tr -d "'" | sed -E "s/[^0-9]//g" | cut -c1-3)

        dumpfile=$(grep -i "^[[:space:]]*dumpfile[[:space:]]*=" "${parfile}" \
            | grep -v "^[[:space:]]*#" | head -1 \
            | sed -E "s/.*=[[:space:]]*//" | tr -d "'\"")
    fi

    local hostname_val
    hostname_val=$(hostname 2>/dev/null || echo "")

    local parallel_mgl="NULL"
    [[ -n "${parallel_degree}" ]] && parallel_mgl="${parallel_degree}"

    info "Writing log entry to rj_dba_datapump_log on ${db} ..."
    sqlplus -s "${db_user}/${db_pass}@${db}" <<SQLEOF
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET FEEDBACK OFF HEADING OFF ECHO OFF

-- Create table if it does not exist (matches current DDL definition)
DECLARE
    v_cnt NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_cnt
    FROM   all_tables
    WHERE  owner    = 'RJ_DBA'
    AND    table_name = 'DATAPUMP_LOG';
    IF v_cnt = 0 THEN
        EXECUTE IMMEDIATE '
        CREATE TABLE rj_dba.datapump_log (
            log_id          NUMBER      DEFAULT "RJ_DBA"."SEQ_FIL_760773".nextval PRIMARY KEY,
            operation       VARCHAR2(10 BYTE),
            db_name         VARCHAR2(100 BYTE),
            username        VARCHAR2(100 BYTE),
            dbname          VARCHAR2(100 BYTE),
            parfile         VARCHAR2(900 BYTE),
            logfile         VARCHAR2(900 BYTE),
            dumpfile        VARCHAR2(900 BYTE),
            job_name        VARCHAR2(200 BYTE),
            parallel_degree NUMBER,
            hostname        VARCHAR2(200),
            start_time      DATE        DEFAULT SYSDATE,
            end_time        DATE,
            status          VARCHAR2(20 BYTE)
        )';
    END IF;
END;
/

INSERT INTO rj_dba.datapump_log
    (operation, db_name, username, dbname, parfile, logfile, dumpfile,
     job_name, parallel_degree, hostname, start_time, end_time, status)
VALUES
    ('${operation}',
     '${db}',
     '${db_user}',
     '${db}',
     '${parfile_contents}',
     '${logfile}',
     '${dumpfile}',
     '${job_name}',
     ${parallel_mgl},
     '${hostname_val}',
     TO_DATE('${start_ts}', 'YYYY-MM-DD HH24:MI:SS'),
     TO_DATE('${end_ts}',   'YYYY-MM-DD HH24:MI:SS'),
     '${status}');
COMMIT;
EXIT 0;
SQLEOF

    local sql_rc=$?
    if [[ $sql_rc -eq 0 ]]; then
        ok "Logged to rj_dba.datapump_log (${operation} / ${status})"
    else
        warn "Could not write to rj_dba.datapump_log (SQLPlus exit ${sql_rc}) — continuing."
    fi
}

# ---------- Run expdp / impdp with a secure password prompt ----------
# Returns 0 if ran/marked-done, 1 if skipped; emits DP_LAST_RC (exit code),
# DP_LAST_START / DP_LAST_END (timestamps).
# and DP_LAST_PASS (password) for the caller to use in dp_log_entry.
run_dp_cmd() {
    local mode="$1" db="$2" parfile="$3" db_user="$4"
    DP_LAST_RC=-1; DP_LAST_START=""; DP_LAST_END=""; DP_LAST_PASS=""
    echo ""
    info "Command: [${mode}] ${db_user}/${db} parfile=${parfile}"
    echo ""
    while true; do
        read -rp "  ▶ [P]roceed  [S]kip  [M]ark as done  [E]xit — " choice || exit 0
        case "${choice,,}" in
            p|run)
                # Retry loop: re-prompt on ORA-01017 (wrong password / error)
                # or any credential-related failure, up to 3 attempts.
                local attempts=0
                while true; do
                    attempts=$(( attempts + 1 ))
                    read -rsp "  Password for ${db_user}@${db}: " DP_LAST_PASS || exit 0; echo ""
                    DP_LAST_START=$(date '+%Y-%m-%d %H:%M:%S')
                    "${mode}" "${db_user}/${DP_LAST_PASS}@${db}" "parfile=${parfile}"
                    DP_LAST_RC=$?
                    DP_LAST_END=$(date '+%Y-%m-%d %H:%M:%S')
                    if [[ $DP_LAST_RC -eq 0 ]]; then
                        ok "${mode} completed successfully."
                        break
                    elif [[ $DP_LAST_RC -eq 127 ]]; then
                        warn "${mode} not found (exit 127) — Oracle environment may not be set."
                        break
                    else
                        warn "${mode} exited with code ${DP_LAST_RC}."
                        read -rp "  Retry password? [Y]es  [N]o / continue  [E]xit — " _retry
                        case "${_retry,,}" in
                            y|yes) continue ;;
                            e|exit) printf "${YELLOW}Exiting workflow.${RESET}\n\n"; exit 0 ;;
                            *) break ;;
                        esac
                    fi
                    if [[ $attempts -ge 3 ]]; then
                        warn "3 attempts failed. Moving on — check the log before proceeding."
                        break
                    fi
                done
                unset attempts _retry
                return 0
                ;;
            m|mark)
                DP_LAST_START=$(date '+%Y-%m-%d %H:%M:%S')
                DP_LAST_END=${DP_LAST_START}
                DP_LAST_RC=0
                ok "Marked as done (assumed successful)."
                return 0
                ;;
            s|skip)
                warn "Skipping ${mode}."
                return 1
                ;;
            e|exit)
                printf "${YELLOW}Exiting workflow.${RESET}\n\n"; exit 0 ;;
            *) warn "Enter P, M, S, or E." ;;
        esac
    done
}

# ---------- BANNER & UPFRONT COLLECTION ----------

printf "\n${BOLD}"
printf "  ┌─────────────────────────────────────────────┐\n"
printf "  │   Oracle Data Pump — End-to-End Workflow Runner   │\n"
printf "  └─────────────────────────────────────────────┘\n"
printf "${RESET}\n"
echo "Each step can be [P]roceeded, [S]kipped, or [E]xited."

echo ""
prompt_required "Ticket name (e.g. RJF000123456)"   TICKET
prompt_required "Source DB name"                      SOURCE_DB
prompt_required "Target DB name"                      TARGET_DB
prompt_required "DB username (e.g. aregukumar)"       DB_USER
prompt_default  "Archive directory" \
    "/export/home/oracle/arvind/log_archive"          ARCHIVE_DIR

# Derived parfile paths (can be overridden below if step 1 is skipped)
PARFILE_SRC="${SCRIPT_DIR}/${TICKET}/expdp_${TICKET}.par"
PARFILE_BKP="${SCRIPT_DIR}/${TICKET}/expdp_${TICKET}_BKP.par"
PARFILE_IMP="${SCRIPT_DIR}/${TICKET}/impdp_${TICKET}.par"
SRC_LOG_PATH=""
BKP_LOG_PATH=""
IMP_LOG_PATH=""

echo ""
info "Ticket    : ${TICKET}"
info "Source DB : ${SOURCE_DB}"
info "Target DB : ${TARGET_DB}"
info "DB User   : ${DB_USER}"
info "Archive   : ${ARCHIVE_DIR}"

# =============================================================================
# STEP 1 — Generate parfiles
# =============================================================================

hdr 1 "Generate parfiles  (datapump.sh)"

if ask_step "Run datapump.sh to create parfiles for ${TICKET}"; then
    "${SCRIPT_DIR}/datapump.sh"
    ok "datapump.sh completed."
fi

# If parfile is still missing (step skipped or wrong ticket), ask for the path
if [[ ! -f "${PARFILE_SRC}" ]]; then
    warn "Source parfile not found: ${PARFILE_SRC}"
    prompt_required "Enter full path to source parfile (expdp_${TICKET}.par)" PARFILE_SRC
fi

# =============================================================================
# STEP 2 — Run SOURCE export
# =============================================================================

hdr 2 "Run SOURCE export  (expdp)"

info "Parfile: ${PARFILE_SRC}"
if run_dp_cmd expdp "${SOURCE_DB}" "${PARFILE_SRC}" "${DB_USER}"; then
    dp_log_entry "${SOURCE_DB}" "${DB_USER}" "${DP_LAST_PASS}" \
        "EXP" "${SRC_LOG_PATH}" "${PARFILE_SRC}" \
        "${DP_LAST_START}" "${DP_LAST_END}" "${DP_LAST_RC}"
    unset DP_LAST_PASS
fi

# =============================================================================
# STEP 3 — Resolve source export log path
# =============================================================================

hdr 3 "Resolve SOURCE export log path  (get_datapump_logfile.sh)"

if ask_step "Query Oracle DIRECTORY to find full NFS log path for ${SOURCE_DB}"; then
    SRC_LOG_PATH=$(
        "${SCRIPT_DIR}/get_datapump_logfile.sh" "${SOURCE_DB}" "${PARFILE_SRC}" \
        | sed -n 's/.*FULL_LOG_PATH[[:space:]]*:[[:space:]]*//p' \
        | tr -d '[[:space:]]'
    )
    if [[ -n "${SRC_LOG_PATH}" ]]; then
        ok "Source log resolved: ${SRC_LOG_PATH}"
    else
        warn "Auto-detect failed — please enter the path manually."
        prompt_required "Full path to source export log" SRC_LOG_PATH
    fi
else
    prompt_required "Full path to source export log (needed for downstream steps)" SRC_LOG_PATH
fi

# =============================================================================
# STEP 4 — Inspect source dumpfiles
# =============================================================================

hdr 4 "Inspect source dumpfiles  (list_dumpfiles.sh)"

if ask_step "Run list_dumpfiles.sh on: ${SRC_LOG_PATH}"; then
    "${SCRIPT_DIR}/list_dumpfiles.sh" "${SRC_LOG_PATH}"
fi

# =============================================================================
# STEP 5 — Run TARGET backup export
# =============================================================================

hdr 5 "Run TARGET backup export  (expdp BKP)"

if [[ ! -f "${PARFILE_BKP}" ]]; then
    warn "BKP parfile not found: ${PARFILE_BKP}"
    prompt_required "Enter full path to BKP parfile" PARFILE_BKP
fi

info "Parfile: ${PARFILE_BKP}"
if run_dp_cmd expdp "${TARGET_DB}" "${PARFILE_BKP}" "${DB_USER}"; then
    dp_log_entry "${TARGET_DB}" "${DB_USER}" "${DP_LAST_PASS}" \
        "EXP_BKP" "${BKP_LOG_PATH}" "${PARFILE_BKP}" \
        "${DP_LAST_START}" "${DP_LAST_END}" "${DP_LAST_RC}"
    unset DP_LAST_PASS
fi

# =============================================================================
# STEP 6 — Run TARGET import
# =============================================================================

hdr 6 "Run TARGET import  (impdp)"

warn "Before proceeding — confirm the following SQL has been applied on TARGET:"
info "  ALTER SYSTEM SET DB_BLOCK_CHECKING = FALSE SCOPE=BOTH;"
info "  ALTER SYSTEM SET DB_BLOCK_CHECKSUM = FALSE SCOPE=BOTH;"
info "  ALTER DATABASE NO FORCE LOGGING;"
info "  (To suppress redo: uncomment transform=DISABLE_ARCHIVE_LOGGING:Y in the impdp parfile)"
echo ""

if [[ ! -f "${PARFILE_IMP}" ]]; then
    warn "Import parfile not found: ${PARFILE_IMP}"
    prompt_required "Enter full path to import parfile" PARFILE_IMP
fi

info "Parfile: ${PARFILE_IMP}"
if run_dp_cmd impdp "${TARGET_DB}" "${PARFILE_IMP}" "${DB_USER}"; then
    dp_log_entry "${TARGET_DB}" "${DB_USER}" "${DP_LAST_PASS}" \
        "IMP" "${IMP_LOG_PATH}" "${PARFILE_IMP}" \
        "${DP_LAST_START}" "${DP_LAST_END}" "${DP_LAST_RC}"
    unset DP_LAST_PASS
    echo ""
    warn "Post-import steps to run on TARGET:"
    info "  1. ALTER SYSTEM SET DB_BLOCK_CHECKING = MEDIUM SCOPE=BOTH;"
    info "  2. ALTER SYSTEM SET DB_BLOCK_CHECKSUM = TYPICAL SCOPE=BOTH;"
    info "  3. ALTER DATABASE FORCE LOGGING;"
    info "  4. VALIDATE CHECK LOGICAL DATABASE;"
    info "  5. Rebuild excluded indexes with PARALLEL N, then NOPARALLEL"
    info "  6. ENABLE NOVALIDATE CONSTRAINT for each deferred constraint"
    info "  7. Re-enable triggers and re-apply grants"
    info "  (Full SQL in POST-IMPORT comment block inside $(basename "${PARFILE_IMP}"))"
fi

# =============================================================================
# STEP 7 — Archive log files  (COMMENTED OUT — not yet in use)
# =============================================================================

# hdr 7 "Archive log files  (archive_logfile.sh)"
# info "Archive destination: ${ARCHIVE_DIR}"
#
# # Derive BKP and IMP log paths from the resolved source log directory
# if [[ -n "${SRC_LOG_PATH}" ]]; then
#     LOG_DIR="$(dirname "${SRC_LOG_PATH}")"
#     BKP_LOG_PATH="${LOG_DIR}/expdp_${TICKET}_BKP.log"
#     IMP_LOG_PATH="${LOG_DIR}/impdp_${TICKET}.log"
# fi
#
# if [[ -n "${SRC_LOG_PATH}" ]]; then
#     if ask_step "Archive source export log: ${SRC_LOG_PATH}"; then
#         ARCHIVE_DIR="${ARCHIVE_DIR}" "${SCRIPT_DIR}/archive_logfile.sh" "${SRC_LOG_PATH}" \
#             || warn "archive_logfile.sh returned non-zero for source log"
#     fi
# else
#     warn "Source log path not resolved — skipping source log archive."
# fi
#
# if [[ -n "${BKP_LOG_PATH}" ]]; then
#     if ask_step "Archive BKP export log: ${BKP_LOG_PATH}"; then
#         ARCHIVE_DIR="${ARCHIVE_DIR}" "${SCRIPT_DIR}/archive_logfile.sh" "${BKP_LOG_PATH}" \
#             || warn "archive_logfile.sh returned non-zero for BKP log"
#     fi
# else
#     warn "BKP log path not resolved — skipping BKP log archive."
# fi
#
# if [[ -n "${IMP_LOG_PATH}" ]]; then
#     if ask_step "Archive import log: ${IMP_LOG_PATH}"; then
#         ARCHIVE_DIR="${ARCHIVE_DIR}" "${SCRIPT_DIR}/archive_logfile.sh" "${IMP_LOG_PATH}" \
#             || warn "archive_logfile.sh returned non-zero for import log"
#     fi
# else
#     warn "Import log path not resolved — skipping import log archive."
# fi

# =============================================================================
# STEP 8 — Schedule dumpfile cleanup  (COMMENTED OUT — not yet in use)
# =============================================================================

# hdr 8 "Schedule dumpfile cleanup  (optional)"
# info "Generates a one-shot cron entry to delete source dumpfiles 16 days after export."
# info "This step is optional — skip if you prefer to run cleanup manually."
#
# if ask_step "Generate cron entry for dumpfile cleanup"; then
#
#     if [[ -z "${SRC_LOG_PATH}" ]]; then
#         warn "Source log path is not set — cannot build cron entry. Run step 3 first or re-run the workflow."
#     else
#         # Back up current crontab (read-only — this script does NOT modify crontab)
#         CRON_BACKUP_PATH="${SCRIPT_DIR}/crontab_backup_$(date '+%Y%m%d_%H%M%S').txt"
#         crontab -l 2>/dev/null > "${CRON_BACKUP_PATH}" || true
#         info "Crontab backed up to: ${CRON_BACKUP_PATH}"
#
#         # Compute fire date: 16 days from now
#         CRON_DATE=$(date -d '+16 days' '+%d %m' 2>/dev/null || date -v+16d '+%d %m' 2>/dev/null || echo "?? ??")
#         CRON_DAY=$(echo "${CRON_DATE}" | awk '{print $1}')
#         CRON_MON=$(echo "${CRON_DATE}" | awk '{print $2}')
#         CRON_TIME=$(date '+%H:%M')
#         CRON_HH=${CRON_TIME%%:*}
#         CRON_MM=${CRON_TIME##*:}
#         CLEANUP_SCRIPT="${SCRIPT_DIR}/remove_dumpfiles_15d.sh"
#         CRON_LOG="${SCRIPT_DIR}/remove_dumpfiles_${TICKET}.log"
#         SRC_LOG_BASENAME="$(basename -- "${SRC_LOG_PATH}")"
#
#         echo ""
#         info "Add the following entry to your crontab  (run: crontab -e):"
#         echo ""
#         printf "   %s %s %s %s * %s %s %s %s_%s\n" \
#             "${CRON_MM}" "${CRON_HH}" "${CRON_DAY}" "${CRON_MON}" \
#             "2>&1 && crontab -l | grep -v ${CRON_LOG} | crontab -\n" \
#             "${CRON_MM}" "${CRON_MON}" \
#             "${CLEANUP_SCRIPT}" "${SRC_LOG_PATH}" "${CRON_LOG}" "_${SRC_LOG_BASENAME}"
#         echo ""
#         echo ""
#         info "Fires once on: $(date -d '+16 days' '+%Y-%m-%d' 2>/dev/null || date -v+16d '+%Y-%m-%d' 2>/dev/null || echo '(16 days from today)') at ${CRON_TIME}"
#         info "Output log    : ${CRON_LOG}"
#         info "The cron entry self-removes after a successful cleanup run."
#     fi
# fi

# ---------- Done ----------
echo ""
sep
printf "${GREEN}${BOLD}  Workflow complete for %s.${RESET}\n" "${TICKET}"
sep
echo ""
