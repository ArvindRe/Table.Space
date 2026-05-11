#!/usr/bin/env bash
# Generates a self-removing one-shot cron entry to delete dumpfiles 16 days after export.
# Author: Arvind Regukumar
set -euo pipefail

# ========== EDIT THESE IF NEEDED ==========
CLEANUP_SCRIPT="/export/home/oracle/arvind/remove_dumpfiles_15d.sh"  # the script that does the cleanup
DEFAULT_LOG_DIR="/export/home/oracle/arvind"                          # where to write the run log
# ==========================================

# Ensure required tools are present
command -v crontab >/dev/null 2>&1 || { echo "ERROR: crontab not found"; exit 1; }
command -v date    >/dev/null 2>&1 || { echo "ERROR: date not found";    exit 1; }

# 1) Ask for the export log path (argument for cleanup script)
read -rp "Enter the full path of the export log file (e.g. /nfs/xs/expdp/EXP-to-STG/expdp_RJF000123456164.log): " EXPORT_LOG
if [[ -z "${EXPORT_LOG}" ]]; then
    echo "ERROR: Export log path is required."
    exit 1
fi

# Warn (don't abort) if the log doesn't exist yet on this host — it may live on a remote NFS mount
if [[ ! -f "${EXPORT_LOG}" ]]; then
    echo "WARN: '${EXPORT_LOG}' not found on this host. Make sure the path is correct before the cron fires."
fi

# 2) Ask for the time-of-day (HH:MM) to run. Default = current time
RUN_HOUR="$(date '+%H:%M')"
read -rp "Enter time-of-day to run (HH:MM, 24h). Default = ${RUN_HOUR}: " RUNTIME
RUNTIME="${RUNTIME:-${RUN_HOUR}}"

# Validate HH:MM
if [[ ! "${RUNTIME}" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    echo "ERROR: Time must be in HH:MM (24h) format."
    exit 1
fi

RUN_HH="${RUNTIME%%:*}"
RUN_MIN="${RUNTIME##*:}"

# 3) Compute the date 16 days from now
RUN_MONTH="$(date -d '+16 days' '+%m')" || { echo "ERROR: 'date -d' failed; this script needs GNU date."; exit 1; }
RUN_DAY="$(date   -d '+16 days' '+%d')"

# 4) Build names derived from the export log filename
EXPORT_BASENAME="$(basename -- "${EXPORT_LOG}")"

# 5) Build a per-run output log file (so you can inspect the cleanup run)
CRON_LOG="${DEFAULT_LOG_DIR}/remove_dumpfiles_${EXPORT_BASENAME}.log"

# 6) Build the cron line
#    - Run the cleanup script directly (no Oracle env needed — it only parses logs and calls rm)
#    - Redirect stdout+stderr to RUN_LOG
#    - On success (exit 0), self-remove this cron entry via grep -v on the log filename
CRONLINE="${RUN_MIN} ${RUN_HH} ${RUN_DAY} ${RUN_MONTH} * ${CLEANUP_SCRIPT} ${EXPORT_LOG} > ${CRON_LOG} 2>&1 && crontab -l | grep -v ${EXPORT_BASENAME} | crontab -"

# 7) Back up current crontab (read-only — this script does NOT modify crontab)
CRON_BACKUP="${DEFAULT_LOG_DIR}/crontab_backup_$(date '+%Y%m%d_%H%M%S').txt"
crontab -l 2>/dev/null > "${CRON_BACKUP}" || true
echo "✔  Crontab backed up to: ${CRON_BACKUP}"

# 8) Print the cron entry for the user to add manually:
echo ""
echo "Add the following entry to your crontab (run: crontab -e):"
echo ""
echo "------------------------------------------------------------"
echo "${CRONLINE}"
echo "------------------------------------------------------------"
echo ""
echo "- Fires once on : $(date -d '+16 days' '+%Y-%m-%d') at ${RUN_HOUR}:${RUN_MIN}"
echo "- Cleanup script: ${CLEANUP_SCRIPT} ${EXPORT_LOG}"
echo "- Output log    : ${CRON_LOG}"
echo ""
echo "Note: The cron entry self-removes after a successful run (exit code 0)."
