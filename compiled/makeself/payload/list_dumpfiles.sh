#!/bin/bash
# Lists dumpfiles from an expdp log with size and timestamps via ls -loch.
# Author: Arvind Regukumar
"$(dirname "$0")/get_dumpfiles.sh" "$1" | xargs ls -loch
