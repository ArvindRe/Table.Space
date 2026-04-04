#!/bin/bash
: "${ZFS_AUTH_HEADER:?ZFS_AUTH_HEADER env var is not set}"
: "${ZFS_ACTION_URL:?ZFS_ACTION_URL env var is not set}"

curl -Ss --insecure -X GET \
"${ZFS_ACTION_URL}" \
-H "authorization: Basic ${ZFS_AUTH_HEADER}" \
-H 'cache-control: no-cache' | python -c 'import json,sys;obj=json.load(sys.stdin);print(obj["action"]["state"])'
