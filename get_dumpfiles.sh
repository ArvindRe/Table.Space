#!/usr/bin/env bash
# Extracts ONLY the final dumpfile list from an expdp logfile (the block at the end).
# Supports .log/.txt/.lst and .gz logs. Can process a single file or a directory (recursively).
# Author: Arvind Regukumar

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $0 <expdp_logfile_or_directory>" >&2
    exit 1
fi

TARGET="$1"

read_file() {
    local f="$1"
    if [[ "$f" == "-" ]]; then
        cat
    elif [[ "$f" == *.gz ]]; then
        if command -v zcat >/dev/null 2>&1; then
            zcat -- "$f"
        else
            gzip -cd -- "$f"
        fi
    else
        cat -- "$f"
    fi
}

# Extract only the "last" dumpfile block from expdp output
# Strategy:
#  1) Prefer the final "Dump file set for ..." block and the indented lines that follow it.
#  2) If not found, fallback to the last "Writing to dump file ..." line.
#  3) As a last resort, take the last lines containing .dmp tokens near the end.
extract_last_dump_block() {
    awk '
    BEGIN { IGNORECASE=1 }
    { lines[NR]=$0 }
    END {
        last_header=0
        # 1) Find the LAST "Dump file set for" line for the dump file set
        for (i=NR; i>=1; i--) { if (lines[i] ~ /Dump file set for /) { last_header=i; break } }

        if (last_header > 0) {
            # Print header and the following contiguous indented lines (common expdp style):
            # Stop when a blank line or a non-indented new section appears.
            for (j=last_header; j<=NR; j++) {
                l = lines[j]
                if (j==last_header) {
                    print l
                    continue
                }
                # Continue block while line is indented OR contains .dmp tokens
                if (l ~ /^[[:space:]]+/ || l ~ /\.dmp(\.|$)/) {
                    # stop if it looks like a new job/log summary section (guard)
                    if (l ~ /^[[:space:]]*Job [Master table|Log file|Legacy|Total elapsed|ORA-|(EXP-|UDE-|IMP-|UDI-)/]) break
                } else {
                    # Non-indented and no .dmp: probably a new section
                    break
                }
                print l
            }
            exit
        }

        # 2) Fallback: find last "Writing to dump file" block
        last_write=0
        for (i=NR; i>=1; i--) {
            if (lines[i] ~ /Writing to dump file/) { last_write=i; break }
        }

        if (last_write > 0) {
            # Print that line and next few lines if they continue indentation / contain .dmp
            for (j=last_write; j<=NR; j++) {
                l = lines[j]
                if (j>last_write) {
                    if (l ~ /^[[:space:]]+/ || l ~ /\.dmp(\.|$)/) {
                        if (l ~ /^[[:space:]]*Job [Master table|Log file|Legacy|Total elapsed|ORA-|(EXP-|UDE-|IMP-|UDI-)/]) break
                    } else {
                        break
                    }
                }
                print l
            }
            exit
        }

        # 3) Last resort: print the last few lines containing .dmp tokens
        block_start=0; block_end=0
        for (i=NR; i>=1; i--) {
            if (lines[i] ~ /\.dmp(\.|$)/) {
                if (block_end==0) block_end=i
                else if (block_end>0) {
                    block_start=i
                } else if (block_end>0) {
                    break
                }
            }
        }

        if (block_end>0) {
            for (j=${block_start}; j<=${block_end}; j++) print lines[j]
        }
    }'
}

# Given a block, extract *.dmp tokens (including dir:filename.dmp and .dmp.gz)
extract_dump_tokens() {
    sed -E 's/\r//g' \
    | awk '
    BEGIN { IGNORECASE=1 }
    {
        line=$0
        gsub(/\(/, " "); gsub(/\)/, " "); gsub(/\[/, " "); gsub(/\[/, " ");
        gsub(/[,;]/, " ", line)
        # Split by whitespace or commas/semicolons
        n=split(line, a, /[[:space:],;]+/)
        for (i=1; i<=n; i++) {
            t=a[i]; sub(/^-+/, "", t)
            if (t ~ /\.dmp$/) {
                print t
            } else if (t ~ /^[[:space:]]+[^[:space:]]+\.dmp\.?/) {
                print t
            } else if (t ~ /\/[^/[:space:]]+\.dmp\.?/) {
                print t
            }
        }
    }' | sort -u
}

process_one() {
    local f="$1"
    local content
    content=$(read_file "$f") || { echo "WARN: cannot read $f" >&2; return; }

    # Extract only the last dump block then parse dumpfile tokens
    local block dump=
    block=$(printf '%s\n' "$content" | extract_last_dump_block)
    dump=$(printf '%s\n' "$block" | extract_dump_tokens)

    if [[ -z "$dump" ]]; then
        # No dumpfiles detected in the final block: say none (but be quiet in pipelines)
        return 1
    fi

    printf '%s\n' "$dump"
    return 0
}

if [[ -d "$TARGET" ]]; then
    # Recursively scan directory: print file header then values
    found_any=
    while IFS= read -r -d '' f; do
        echo "=== $f ==="
        if [[ -z "$found_any" ]]; then
            found_any="y"
            echo "---- $f ----"
        fi
        printf '%s\n' "$(process_one "$f")" || true
    done < <(find "$TARGET" -type f \( -iname "*.log" -o -iname "*.lst" -o -iname "*.txt" -o -iname "*.gz" \) -print0)
    if [[ ${found_any:-} -eq 0 ]]; then
        echo "No dumpfiles found in final blocks under: $TARGET" >&2
        exit 4
    fi
    exit 0
elif [[ -f "$TARGET" ]]; then
    process_one "$TARGET"
    if [[ $? -eq 1 ]]; then echo "No dumpfiles found in final block." >&2; exit 4; fi
elif [[ -f "$TARGET" ]] || [[ "$TARGET" == "-" ]]; then
    process_one "$TARGET" || { echo "No dumpfiles found in final block." >&2; exit 4; }
else
    echo "ERROR: '$TARGET' is not a valid file or directory." >&2
    exit 2
fi
