#!/usr/bin/env bash
# run_exports_parallel.sh - Execute multiple expdp parfiles with a configurable worker pool.
#
# Usage:
#   ./run_exports_parallel.sh -u <db_user> -d <db_tns> [-j <max_parallel>] [-n] [-o <dir>] parfile1 [parfile2 ...]
#
# See README.md for full documentation.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=dp_parallel_lib.sh
source "${SCRIPT_DIR}/dp_parallel_lib.sh"

# --- Main -------------------------------------------------------------------
main() {
    parse_args "expdp" "$@"
    init_logging "expdp"
    validate_parfiles
    prompt_password

    # Set cleanup trap after password is stored
    trap cleanup_trap EXIT INT TERM

    run_worker_pool "expdp"
    local pool_rc=$?

    print_summary
    exit "${pool_rc}"
}

main "$@"
