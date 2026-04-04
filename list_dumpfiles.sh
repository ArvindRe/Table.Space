#!/bin/bash
"$(dirname "$0")/get_dumpfiles.sh" "$1" | xargs ls -loch
