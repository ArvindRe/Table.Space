#!/bin/bash
: "${ZFS_AUTH_HEADER:?ZFS_AUTH_HEADER env var is not set}"
: "${ZFS_ACTION_URL:?ZFS_ACTION_URL env var is not set}"

echo "Start ZFS sync."

curl --insecure -X PUT \
"${ZFS_ACTION_URL}/sendupdate" \
-H "authorization: Basic ${ZFS_AUTH_HEADER}" \
-H 'cache-control: no-cache'

# run 20 times
for ((i=1;i<=20;i++))
do
    ref_response=$(curl -Ss --insecure -X GET \
    "${ZFS_ACTION_URL}" \
    -H "authorization: Basic ${ZFS_AUTH_HEADER}" \
    -H 'cache-control: no-cache' | python -c 'import json,sys;obj=json.load(sys.stdin);print(obj["action"]["state"])')

    # check for the status
    if [ $ref_response != "idle" ]
    then
        # sync still running
        echo "Zfs sync still running"
        # wait for 300 seconds, then start another iteration
        sleep 300
    else
        # exit from the cycle
        echo "Zfs sync completed"
        break
    fi
done
exit 0
