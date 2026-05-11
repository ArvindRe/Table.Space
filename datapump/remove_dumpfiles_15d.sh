#!/usr/bin/env bash
# remove_dumpfiles_15d.sh
# Deletes dumpfiles (identified via expdp log) older than 15 days.
# Author: Arvind Regukumar
# Usage: ./remove_dumpfiles_15d.sh /nfs/xs/expdp/EXP-to-STG/expdp_TICKET_BKP.log
# Set DRY_RUN=1 to preview without deleting.

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <dumpfile_list_input_to_get_dumpfiles.sh>"
    exit 1
fi

INPUT="$1"
DRY_RUN="${DRY_RUN:-0}"
LOGFILE="${LOGFILE:-/tmp/remove_dumpfiles_15d.log}"

# Compute threshold: files last modified on or before this timestamp will be deleted.
THRESHOLD_TS="$(date -d '15 days ago' '+%s')"

echo "=== $(date '+%F %T') | Starting cleanup (15 days old).  Dry-run: ${DRY_RUN}" | tee -a "$LOGFILE"

# Get the directory where THIS script resides, even if invoked via cron or symlink
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

"${SCRIPT_DIR}/get_dumpfiles.sh" "$INPUT" | while IFS= read -r file; do
    # Skip empty lines
    [[ -z "$file" ]] && continue

    # Optional: only act on .dmp files (uncomment if you want to restrict)
    # [[ "$file" != *.dmp ]] && continue

    if [[ -e "$file" ]]; then
        # Get file's last modification time (epoch seconds)
        mtime_ts="$(stat -c '%Y' "$file" 2>/dev/null || true)"
        if [[ -z "${mtime_ts:-}" ]]; then
            echo "WARN: Could not stat: $file" | tee -a "$LOGFILE"
            continue
        fi

        if [[ $(( mtime_ts <= THRESHOLD_TS )) ]]; then
            if [[ "${DRY_RUN}" -eq 1 ]]; then
                echo "Would remove (older than 15d): $file" | tee -a "$LOGFILE"
            else
                echo "Removing (older than 15d): $file" | tee -a "$LOGFILE"
                rm -f -- "$file"
            fi
        else
            # Optional: comment out if you want silent skip
            echo "Skipping (newer than 15d): $file" >> "$LOGFILE"
        fi
    else
        echo "Not found (skip): $file" | tee -a "$LOGFILE"
    fi
done

echo "=== $(date '+%F %T') | Cleanup done." | tee -a "$LOGFILE"
