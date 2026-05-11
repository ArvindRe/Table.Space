#!/usr/bin/env bash
# Frontend wrapper: report GV$RESOURCE_LIMIT for processes, sessions, and transactions.
# After displaying results, detects instances where processes or sessions exceed
# HIGH_PCT% of their limit and offers an interactive root-cause investigation.
# Usage: ./get_resource_limit.sh <DB_NAME>
# Author: Arvind Regukumar

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB_NAME="${1:-}"

if [[ -z "${DB_NAME}" ]]; then
    echo "Usage: $(basename "$0") <DB_NAME>" >&2
    exit 2
fi

# ---------- Colour helpers ----------
RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m';   RESET='\033[0m'

warn()  { printf "${YELLOW}⚠  %s${RESET}\n" "$*"; }
alert() { printf "${RED}✖  %s${RESET}\n" "$*"; }
sep()   { printf "${CYAN}%s${RESET}\n" "──────────────────────────────────────────────────────────"; }

# Instances are flagged when current_utilisation OR max_utilisation / limit >= this percentage
HIGH_PCT=65

# ---------- Step 1: run resource limit report — display live and capture for parsing ----------
TMPOUT=$(mktemp /tmp/rl_output.XXXXXXXXXX)
trap "rm -f '${TMPOUT}'" EXIT

/export/home/oracle/bin/get_pw.sh cx6dapopd dbsnmp \
    | "${SCRIPT_DIR}/run_get_resource_limit.sh" -m "${DB_NAME}" -p - \
    | tee "${TMPOUT}"
pipe_rcs=("${PIPESTATUS[@]}")

if [[ ${pipe_rcs[1]} -ne 0 ]]; then
    echo "ERROR: Resource limit query failed (exit ${pipe_rcs[1]})." >&2
    exit "${pipe_rcs[1]}"
fi

# ---------- Step 2: detect high-utilisation instances ----------
# Table line format (processes / sessions rows only):
#   5 processes       2241  3572    3572
# Fields: INST  RESOURCE_NAME  CURRENT  MAX_HIST  LIMIT
declare -A INST_FLAGS   # [inst_id] -> "resource:pct ..."

while IFS= read -r line; do
    read -r inst res cur max_val lim <<< "${line}"
    [[ "${inst}" =~ ^[0-9]+$ ]]                          || continue
    [[ "${res}" == "processes" || "${res}" == "sessions" ]] || continue
    [[ "${lim}" =~ ^[0-9]+$ && "${lim}" -gt 0 ]]        || continue
    cur_pct=$(( cur * 100 / lim ))
    max_pct=$(( max_val * 100 / lim ))
    if [[ $(( cur_pct )) -ge ${HIGH_PCT} ]]; then
        entry="${res}:${cur_pct}%  current"
        INST_FLAGS["${inst}"]="${INST_FLAGS["${inst}"]:-}  ${INST_FLAGS["${inst}"]:+|}[inst ${inst}]:${INST_FLAGS["${inst}"]}"  }[entry]"
    elif [[ $(( max_pct )) -ge ${HIGH_PCT} ]]; then
        entry="${res}:${max_pct}% max (now ${cur_pct}%)"
        INST_FLAGS["${inst}"]="${INST_FLAGS["${inst}"]:-}${INST_FLAGS["${inst}"]:+|}[inst ${inst}]:${INST_FLAGS["${inst}"]}"  }[entry]"
    fi
done < "${TMPOUT}"

# ---------- Step 3: exit cleanly if no instances are near their limits ----------
if [[ ${#INST_FLAGS[@]} -eq 0 ]]; then
    exit 0
fi

# ---------- Step 4: warn about flagged instances and prompt for investigation ----------
echo ""
sep
alert "HIGH RESOURCE UTILISATION DETECTED"
sep
for inst_id in $(printf '%s\n' "${!INST_FLAGS[@]}" | sort -n); do
    alert "  Instance ${inst_id}:  ${INST_FLAGS[${inst_id}]}"
done
echo ""

while true; do
    printf "${BOLD}  [I]nvestigate root cause on flagged instance(s)?${RESET}\n"
    read -rp "  [I]nvestigate  [E]xit — " choice
    case "${choice,,}" in
        i|investigate) break ;;
        e|exit)
            printf "${YELLOW}Exiting.${RESET}\n\n"; exit 0 ;;
        *)
            warn "Enter I or E." ;;
    esac
done

# ---------- Step 5: run drill-down for flagged instances ----------
INST_LIST=$(printf '%s\n' "${!INST_FLAGS[@]}" | sort -n | paste -sd ',')
echo ""
/export/home/oracle/bin/get_pw.sh cx6dapopd dbsnmp \
    | "${SCRIPT_DIR}/run_get_resource_drilldown.sh" -a "${DB_NAME}" -i "${INST_LIST}" -p -
