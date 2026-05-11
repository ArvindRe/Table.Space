#!/usr/bin/env bash
# run_imports_parallel.sh - Execute multiple impdp parfiles with a configurable worker pool.
#
# Usage:
#   ./run_imports_parallel.sh -u <db_user> -d <db_tns> [-j <max_parallel>] [-n] [-o <dir>] parfile1 [parfile2 ...]
#
# See README.md for full documentation.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=dp_parallel_lib.sh
source "${SCRIPT_DIR}/dp_parallel_lib.sh"

# --- Main -------------------------------------------------------------------
main() {
    parse_args "impdp" "$@"
    validate_parfiles
    prompt_password

    # Set cleanup trap after password is stored
    trap cleanup_trap EXIT INT TERM

    run_worker_pool "impdp"
    local pool_rc=$?

    print_summary
    exit "${pool_rc}"
}

main "$@"
