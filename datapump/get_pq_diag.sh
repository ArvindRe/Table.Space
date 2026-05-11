#!/usr/bin/env bash
# ORA-12805 parallel query diagnostic — frontend wrapper.
# Runs the PQ diagnostic report and optionally scopes to specific instances.
# Usage: ./get_pq_diag.sh <DB_NAME> [inst_id,inst_id,...]
# Author: Arvind Regukumar

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB_NAME="${1:-}"
INST_LIST="${2:-}"

if [[ -z "${DB_NAME}" ]]; then
    echo "Usage: $(basename "$0") <DB_NAME> [inst_id,inst_id,...]" >&2
    echo "" >&2
    echo "Examples:" >&2
    echo "  $(basename "$0") cxl4scdsqa             # all instances" >&2
    echo "  $(basename "$0") cxl4scdsqa 3,4          # instances 3 and 4 only" >&2
    exit 2
fi

# Validate instance list if provided
if [[ -n "${INST_LIST}" ]] && [[ ! "${INST_LIST}" =~ ^[0-9]+([,][0-9]+)*$ ]]; then
    echo "ERROR: Instance list must be comma-separated integers (e.g. 3,4)." >&2
    exit 2
fi

# Build optional -i flag
INST_FLAG=()
if [[ -n "${INST_LIST}" ]]; then
    INST_FLAG=(-i "${INST_LIST}")
fi

/export/home/oracle/bin/get_pw.sh cx6dapspd dbsnmp \
    | "${SCRIPT_DIR}/run_get_pq_diag.sh" -m "${DB_NAME}" "${INST_FLAG[@]}" -p -
