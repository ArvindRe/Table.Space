#!/usr/bin/env bash
# Frontend wrapper: TEMP tablespace utilisation check across all RAC instances.
# Displays current allocation vs capacity per tempfile, active sort/hash consumers,
# and N-day historical peak from AWR.
# Flags instances where used TEMP exceeds HIGH_PCT% of total TEMP capacity and
# offers an interactive drilldown to active temp consumers.
# Usage: ./get_temp_usage.sh <DB_NAME> [--days N]
# Author: Arvind Regukumar

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB_NAME="${1:-}"
DAYS=7

# Allow --days to be passed as a second argument
if [[ "${2:-}" == "--days" && -n "${3:-}" ]]; then
    DAYS="${3}"
fi

if [[ -z "${DB_NAME}" ]]; then
    echo "Usage: $(basename "$0") <DB_NAME> [--days N]" >&2
    exit 2
fi

# ---------- Colour helpers ----------
RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m';   RESET='\033[0m'

warn()  { printf "${YELLOW}⚠  %s${RESET}\n" "$*"; }
alert() { printf "${RED}✖  %s${RESET}\n" "$*"; }
sep()   { printf "${CYAN}%s${RESET}\n" "──────────────────────────────────────────────────────────"; }

# Instances are flagged when used TEMP >= this percentage of total TEMP capacity
HIGH_PCT=80

# ---------- Step 1: run TEMP report — display live and capture for parsing ----------
TMPOUT=$(mktemp /tmp/temp_output.XXXXXXXXXX)
trap "rm -f '${TMPOUT}'" EXIT

/export/home/oracle/bin/get_pw.sh "${DB_NAME}" dbsnmp \
    | "${SCRIPT_DIR}/run_get_temp_usage.sh" -a "${DB_NAME}" -p - --days "${DAYS}" \
    | tee "${TMPOUT}"
pipe_rcs=("${PIPESTATUS[@]}")

if [[ ${pipe_rcs[1]} -ne 0 ]]; then
    echo "ERROR: TEMP usage query failed (exit ${pipe_rcs[1]})." >&2
    exit "${pipe_rcs[1]}"
fi

# ---------- Step 2: detect high-TEMP instances ----------
# run_get_temp_usage.sh emits TEMPCHK sentinel lines:
#   TEMPCHK <inst_id> <used_mb> <total_mb>
declare -A INST_FLAGS

while IFS= read -r line; do
    read -r tag inst used_mb total_mb <<< "${line}"
    [[ "${tag}" == "TEMPCHK" ]]                                    || continue
    [[ "${inst}" =~ ^[0-9]+$ ]]                                    || continue
    [[ "${total_mb}" =~ ^[0-9]+$ && "${total_mb}" -gt 0 ]]        || continue
    pct=$(( used_mb * 100 / total_mb ))
    if [[ ${pct} -ge ${HIGH_PCT} ]]; then
        INST_FLAGS["${inst}"]="${used_mb} MB used (${pct}% of ${total_mb} MB capacity)"
    fi
done < "${TMPOUT}"

# ---------- Step 3: exit cleanly if no instances are near capacity ----------
if [[ ${#INST_FLAGS[@]} -eq 0 ]]; then
    exit 0
fi

# ---------- Step 4: warn about flagged instances and prompt for investigation ----------
echo ""
sep
alert "HIGH TEMP UTILISATION DETECTED"
sep
for inst_id in $(printf '%s\n' "${!INST_FLAGS[@]}" | sort -n); do
    alert "  Instance ${inst_id}:  ${INST_FLAGS[${inst_id}]}"
done
echo ""

while true; do
    printf "${BOLD}  Investigate top TEMP consumers on flagged instance(s)?${RESET}\n"
    read -rp "  [I]nvestigate  [E]xit — " choice
    case "${choice,,}" in
        i|investigate) break ;;
        e|exit)
            printf "${YELLOW}Exiting.${RESET}\n\n"; exit 0 ;;
        *)
            warn "Enter I or E." ;;
    esac
done

# ---------- Step 5: run drilldown for flagged instances ----------
INST_LIST=$(printf '%s\n' "${!INST_FLAGS[@]}" | sort -n | paste -sd ',')
echo ""
/export/home/oracle/bin/get_pw.sh "${DB_NAME}" dbsnmp \
    | "${SCRIPT_DIR}/run_get_temp_drilldown.sh" -a "${DB_NAME}" -i "${INST_LIST}" -p -
