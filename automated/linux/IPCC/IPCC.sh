#!/bin/sh

. automated/lib/sh-test-lib

OUTPUT="$(pwd)/automated/linux/IPCC/output"
RESULT_FILE="${OUTPUT}/result.txt"
export RESULT_FILE

create_out_dir "${OUTPUT}"
TCID="IPCC_Test"

output=$(cat /sys/class/remoteproc/remoteproc*/state)

count=$(echo "$output" | grep -c "running")

if [ $count -eq 4 ]; then
    echo "pil_loading PASS"
	info_msg "pil_loading TEST PASSED."
	report_pass "${TCID}"
else
    echo "pil_loading FAIL"
	info_msg "pil_loading TEST FAILED."
	report_fail "${TCID}"
fi
