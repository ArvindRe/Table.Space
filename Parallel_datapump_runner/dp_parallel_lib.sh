#!/usr/bin/env bash
# dp_parallel_lib.sh - Shared worker-pool logic for parallel Data Pump execution.
# Source this file; do not execute directly.
# Requires: bash 4.3+ (for wait -n and associative arrays)

set -o pipefail

# --- Globals ----------------------------------------------------------------
declare -a PARFILES=()
declare    DB_USER=""
declare    DB_TNS=""
declare    _DP_PASS=""
declare -i MAX_JOBS=3
declare    DRY_RUN=0
declare    OUTPUT_DIR="."
declare    LOG_DIR="${SCRIPT_DIR}/logs"
declare    LOG_FILE=""

# Results tracking (indexed arrays, same order)
declare -a RES_PARFILE=()
declare -a RES_RC=()
declare -a RES_START=()
declare -a RES_END=()

# --- Logging ----------------------------------------------------------------
# init_logging <tool>
# Creates logs/ dir, opens a timestamped log file, and tees all subsequent
# stdout/stderr to it. Call after parse_args so LOG_DIR is set.
init_logging() {
    local tool="${1}"
    mkdir -p "${LOG_DIR}" || { echo "ERROR: Cannot create log directory: ${LOG_DIR}" >&2; exit 1; }
    LOG_FILE="${LOG_DIR}/${tool}_parallel_$(date '+%Y%m%d_%H%M%S').log"
    exec > >(tee -a "${LOG_FILE}") 2>&1
    echo "Logging to: ${LOG_FILE}"
}

# --- Usage ------------------------------------------------------------------
usage() {
    local tool="${1:-expdp}"
    cat <<EOS
Usage: $(basename "$0") -u <db_user> -d <db_tns_alias> [-j <max_parallel>] [-n] [-o <output_dir>] <parfile1> [parfile2 ...]

Options:
  -u <db_user>       Database username (required)
  -d <db_tns_alias>  TNS alias / connect string for the target database (required)
  -j <max_parallel>  Maximum concurrent ${tool} sessions (default: 3)
  -n                 Dry-run mode - print commands without executing
  -o <output_dir>    Directory for per-job output files (default: current dir)
  -h                 Show this help

Arguments:
  One or more parfile paths to execute with ${tool}.

Example:
  $(basename "$0") -u SYSTEM -d PRODDB -j 4 /tmp/parfiles/exp_*.par
EOS
    exit "${2:-0}"
}

# --- Argument Parsing -------------------------------------------------------
# parse_args <tool_name> "$@"  - tool_name is "expdp" or "impdp"
parse_args() {
    local _tool="${1}"; shift
    OPTIND=1
    while getopts ":u:d:j:o:nh" opt "$@"; do
        case "${opt}" in
            u) DB_USER="${OPTARG}" ;;
            d) DB_TNS="${OPTARG}" ;;
            j) MAX_JOBS="${OPTARG}" ;;
            o) OUTPUT_DIR="${OPTARG}" ;;
            n) DRY_RUN=1 ;;
            h) usage "${_tool}" 0 ;;
            :) echo "ERROR: Option -${OPTARG} requires an argument." >&2; exit 1 ;;
            *) echo "ERROR: Unknown option -${OPTARG}" >&2; usage "${_tool}" 1 ;;
        esac
    done
    done
    shift $((OPTIND - 1))

    # Remaining args are parfiles
    PARFILES=("$@")

    # Validate required params
    if [[ -z "${DB_USER}" ]]; then
        echo "ERROR: -u <db_user> is required." >&2
        exit 1
    fi
    if [[ -z "${DB_TNS}" ]]; then
        echo "ERROR: -d <db_tns_alias> is required." >&2
        exit 1
    fi
    if [[ ${#PARFILES[@]} -eq 0 ]]; then
        echo "ERROR: At least one parfile must be specified." >&2
        exit 1
    fi
    if ! [[ "${MAX_JOBS}" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: -j must be a positive integer." >&2
        exit 1
    fi
}

# --- Parfile Validation -----------------------------------------------------
validate_parfiles() {
    local errors=0
    for pf in "${PARFILES[@]}"; do
        if [[ ! -f "${pf}" ]]; then
            echo "ERROR: Parfile not found: ${pf}" >&2
            errors=$((errors + 1))
        elif [[ ! -r "${pf}" ]]; then
            echo "ERROR: Parfile not readable: ${pf}" >&2
            errors=$((errors + 1))
        fi
    done
    if ((errors > 0)); then
        echo "ERROR: ${errors} parfile(s) failed validation. Aborting." >&2
        exit 1
    fi
    # Ensure output directory exists
    if [[ ! -d "${OUTPUT_DIR}" ]]; then
        mkdir -p "${OUTPUT_DIR}" || { echo "ERROR: Cannot create output directory: ${OUTPUT_DIR}" >&2; exit 1; }
    fi
}

# --- Credential Prompt ------------------------------------------------------
prompt_password() {
    read -rsp "Password for ${DB_USER}@${DB_TNS}: " _DP_PASS
    echo ""
    if [[ -z "${_DP_PASS}" ]]; then
        echo "ERROR: Password cannot be empty." >&2
        exit 1
    fi
}

# --- Cleanup Trap -----------------------------------------------------------
cleanup_trap() {
    # Kill all background children of this script
    local kids
    kids=$(jobs -p 2>/dev/null)
    if [[ -n "${kids}" ]]; then
        echo ""
        echo "Signal received - terminating running jobs..."
        # shellcheck disable=SC2086
        kill ${kids} 2>/dev/null
        wait 2>/dev/null
    fi
    _DP_PASS=""
    unset _DP_PASS
}

# --- Worker Pool ------------------------------------------------------------
# run_worker_pool <tool> - tool is "expdp" or "impdp"
# Reads from global PARFILES array
run_worker_pool() {
    local tool="${1}"
    local -i queue_idx=0
    local -i total=${#PARFILES[@]}
    local -i running=0
    local -i completed=0
    local -i any_failed=0

    # Associative arrays for tracking active jobs
    declare -A pid_to_parfile=()
    declare -A pid_to_start=()
    declare -A pid_to_outfile=()

    echo "------------------------------------------------------------"
    echo " Parallel ${tool} Runner"
    echo " User: ${DB_USER}@${DB_TNS} | Concurrency: ${MAX_JOBS} | Parfiles: ${total}"
    if ((DRY_RUN)); then
        echo " *** DRY-RUN MODE - no jobs will be executed ***"
    fi
    echo "------------------------------------------------------------"
    echo ""

    # --- Dry-run: just print commands ---
    if ((DRY_RUN)); then
        for ((i = 0; i < total; i++)); do
            echo "[DRY-RUN] ${tool} ${DB_USER}/******@${DB_TNS} parfile=${PARFILES[i]}"
        done
        echo ""
        echo "Dry-run complete. ${total} job(s) would be launched (max ${MAX_JOBS} concurrent)."
        return 0
    fi

    # --- Launch initial batch ---
    while ((queue_idx < total && running < MAX_JOBS)); do
        _launch_job "${tool}" "${queue_idx}"
        ((queue_idx++))
        ((running++))
    done

    # --- Wait loop ---
    while ((running > 0)); do
        # Try wait -n (bash 4.3+): waits for any single child to exit
        if wait -n 2>/dev/null; then
            _reap_finished "${tool}" 0
        else
            # wait -n returns non-zero if the child exited non-zero, or if unsupported
            # Check if it's because a child failed or because wait -n isn't available
            if _has_wait_n; then
                _reap_finished "${tool}" 1
            else
                # Fallback: poll with kill -0
                _poll_wait "${tool}"
            fi
        fi

        # Reap may have freed a slot - launch next if available
        while ((queue_idx < total && running < MAX_JOBS)); do
            _launch_job "${tool}" "${queue_idx}"
            ((queue_idx++))
            ((running++))
        done
    done

    # Return overall status
    return "${any_failed}"
}

# --- Internal: launch a single job ------------------------------------------
_launch_job() {
    local tool="${1}"
    local -i idx="${2}"
    local pf="${PARFILES[idx]}"
    local base
    base=$(basename "${pf}")
    local outfile="${OUTPUT_DIR}/${base}.out"
    local start_ts
    start_ts=$(date '+%Y-%m-%d %H:%M:%S')

    echo "[$(date '+%H:%M:%S')] LAUNCH  [$(( idx + 1 ))/${#PARFILES[@]}] ${base}"

    "${tool}" "${DB_USER}/${_DP_PASS}@${DB_TNS}" "parfile=${pf}" \
        > "${outfile}" 2>&1 &
    local pid=$!

    pid_to_parfile[${pid}]="${pf}"
    pid_to_start[${pid}]="${start_ts}"
    pid_to_outfile[${pid}]="${outfile}"
}

# --- Internal: check if bash supports wait -n -------------------------------
_has_wait_n() {
    (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3) ))
}

# --- Internal: reap finished jobs (called after wait -n returns) ------------
_reap_finished() {
    local tool="${1}"
    local -i wait_rc="${2}"

    # Find which PID(s) are no longer running
    for pid in "${!pid_to_parfile[@]}"; do
        if ! kill -0 "${pid}" 2>/dev/null; then
            wait "${pid}" 2>/dev/null
            local rc=$?
            _record_result "${pid}" "${rc}"
        fi
    done
}

# --- Internal: polling fallback for bash < 4.3 ------------------------------
_poll_wait() {
    local tool="${1}"
    while true; do
        for pid in "${!pid_to_parfile[@]}"; do
            if ! kill -0 "${pid}" 2>/dev/null; then
                wait "${pid}" 2>/dev/null
                local rc=$?
                _record_result "${pid}" "${rc}"
                return
            fi
        done
        sleep 5
    done
}

# --- Internal: record result and update counters ----------------------------
_record_result() {
    local pid="${1}"
    local -i rc="${2}"
    local pf="${pid_to_parfile[${pid}]}"
    local start_ts="${pid_to_start[${pid}]}"
    local end_ts
    end_ts=$(date '+%Y-%m-%d %H:%M:%S')
    local base
    base=$(basename "${pf}")

    # Store result
    RES_PARFILE+=("${pf}")
    RES_RC+=("${rc}")
    RES_START+=("${start_ts}")
    RES_END+=("${end_ts}")

    # Print status line
    if ((rc == 0)); then
        echo "[$(date '+%H:%M:%S')] DONE    ${base} - exit code 0 (success)"
    else
        echo "[$(date '+%H:%M:%S')] FAILED  ${base} - exit code ${rc}"
        any_failed=1
    fi

    # Remove from active tracking
    unset "pid_to_parfile[${pid}]"
    unset "pid_to_start[${pid}]"
    unset "pid_to_outfile[${pid}]"

    running=$((running - 1))
    completed=$((completed + 1))
}

# --- Summary ----------------------------------------------------------------
print_summary() {
    local -i total=${#RES_PARFILE[@]}
    local -i failed=0

    echo ""
    echo "------------------------------------------------------------"
    echo " SUMMARY"
    echo "------------------------------------------------------------"
    printf "%-40s %-6s %-20s %-20s %-10s\n" "PARFILE" "RC" "START" "END" "ELAPSED"
    printf "%-40s %-6s %-20s %-20s %-10s\n" "--------" "--" "------" "---" "-------"

    for ((i = 0; i < total; i++)); do
        local base
        base=$(basename "${RES_PARFILE[i]}")
        # Compute elapsed time
        local -i s_epoch e_epoch diff_sec
        s_epoch=$(date -d "${RES_START[i]}" '+%s' 2>/dev/null) || s_epoch=0
        e_epoch=$(date -d "${RES_END[i]}"   '+%s' 2>/dev/null) || e_epoch=0
        diff_sec=$((e_epoch - s_epoch))
        local elapsed
        if ((diff_sec < 0)); then
            elapsed="N/A"
        else
            local -i hh mm ss
            hh=$((diff_sec / 3600))
            mm=$(( (diff_sec % 3600) / 60 ))
            ss=$((diff_sec % 60))
            elapsed=$(printf "%02d:%02d:%02d" "${hh}" "${mm}" "${ss}")
        fi
        printf "%-40s %-6s %-20s %-20s %-10s\n" \
            "${base}" "${RES_RC[i]}" "${RES_START[i]}" "${RES_END[i]}" "${elapsed}"
        if ((RES_RC[i] != 0)); then
            failed=$((failed + 1))
        fi
    done

    echo ""
    echo "Total: ${total} | Succeeded: $(( total - failed )) | Failed: ${failed}"
    echo "Per-job output logs are in: ${OUTPUT_DIR}/"
    echo "------------------------------------------------------------"

    return $((failed > 0 ? 1 : 0))
}
