#!/usr/bin/env bash
# Frontend wrapper: PGA utilisation check across all RAC instances.
# Displays current GV$PGASTAT snapshot, N-day historical trend, and peak per instance.
# Flags instances where current PGA allocation exceeds HIGH_PCT% of pga_aggregate_target
# and offers an interactive drilldown to top PGA consumers.
# Usage: ./get_pga.sh <DB_NAME> [--days N]
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

# Instances are flagged when current PGA allocation >= this percentage of pga_aggregate_target
HIGH_PCT=80

# ---------- Step 1: run PGA report — display live and capture for parsing ----------
TMPOUT=$(mktemp /tmp/pga_output.XXXXXXXXXX)
trap "rm -f '${TMPOUT}'" EXIT

/export/home/oracle/bin/get_pw.sh "${DB_NAME}" dbsnmp \
    | "${SCRIPT_DIR}/run_get_pga.sh" -a "${DB_NAME}" -p - --days "${DAYS}" \
    | tee "${TMPOUT}"
pipe_rcs=("${PIPESTATUS[@]}")

if [[ ${pipe_rcs[1]} -ne 0 ]]; then
    echo "ERROR: PGA query failed (exit ${pipe_rcs[1]})." >&2
    exit "${pipe_rcs[1]}"
fi

# ---------- Step 2: detect high-PGA instances ----------
# run_get_pga.sh outputs PGACHK lines: PGACHK <inst_id> <alloc_mb> <target_mb>
declare -A INST_FLAGS

while IFS= read -r line; do
    read -r tag inst alloc_mb target_mb <<< "${line}"
    [[ "${tag}" == "PGACHK" ]]                                    || continue
    [[ "${inst}" =~ ^[0-9]+$ ]]                                   || continue
    [[ "${target_mb}" =~ ^[0-9]+$ && "${target_mb}" -gt 0 ]]     || continue
    pct=$(( alloc_mb * 100 / target_mb ))
    if [[ ${pct} -ge ${HIGH_PCT} ]]; then
        INST_FLAGS["${inst}"]="${alloc_mb} MB allocated (${pct}% of ${target_mb} MB target)"
    fi
done < "${TMPOUT}"

# ---------- Step 3: exit cleanly if no instances are near their limit ----------
if [[ ${#INST_FLAGS[@]} -eq 0 ]]; then
    exit 0
fi

# ---------- Step 4: warn about flagged instances and prompt for investigation ----------
echo ""
sep
alert "HIGH PGA UTILISATION DETECTED"
sep
for inst_id in $(printf '%s\n' "${!INST_FLAGS[@]}" | sort -n); do
    alert "  Instance ${inst_id}:  ${INST_FLAGS[${inst_id}]}"
done
echo ""

while true; do
    printf "${BOLD}  Investigate top PGA consumers on flagged instance(s)?${RESET}\n"
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
    | "${SCRIPT_DIR}/run_get_pga_drilldown.sh" -a "${DB_NAME}" -i "${INST_LIST}" -p -
