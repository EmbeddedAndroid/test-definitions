#!/bin/sh

. automated/lib/sh-test-lib

OUTPUT="$(pwd)/automated/linux/pil-bootup/output"
RESULT_FILE="${OUTPUT}/result.txt"
export RESULT_FILE

create_out_dir "${OUTPUT}"
TCID="PIL_Loading_Test"

# Execute the command and get the output
output=$(cat /sys/class/remoteproc/remoteproc*/state)

# Count the number of "running" values
count=$(echo "$output" | grep -c "running")

# Check if the count is 4
if [ $count -eq 4 ]; then
    echo "pil_loading PASS"
	info_msg "pil_loading TEST PASSED."
	report_pass "${TCID}"
else
    echo "pil_loading FAIL"
	info_msg "pil_loading TEST FAILED."
	report_fail "${TCID}"
fi
