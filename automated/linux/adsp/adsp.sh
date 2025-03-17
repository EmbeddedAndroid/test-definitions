#!/bin/sh

. automated/lib/sh-test-lib

OUTPUT="$(pwd)/automated/linux/adsp/output"
RESULT_FILE="${OUTPUT}/result.txt"
export RESULT_FILE

create_out_dir "${OUTPUT}"
TCID="ADSP_Test"

# Get the firmware output and find the position of adsp
firmware_output=$(cat /sys/class/remoteproc/remoteproc*/firmware)
adsp_position=$(echo "$firmware_output" | grep -n "adsp" | cut -d: -f1)

# Adjust the position to match the remoteproc numbering (starting from 0)
remoteproc_number=$((adsp_position - 1))

# Construct the remoteproc path based on the adsp position
remoteproc_path="/sys/class/remoteproc/remoteproc${remoteproc_number}"

# Execute command 1 and check if the output is "running"
state1=$(cat ${remoteproc_path}/state)
if [ "$state1" != "running" ]; then
    echo "adsp FAIL"
	info_msg "adsp TEST FAILED."
	report_fail "${TCID}"
    exit 1
fi

# Execute command 2 (no output expected)
echo stop > ${remoteproc_path}/state

# Execute command 3 and check if the output is "offline"
state3=$(cat ${remoteproc_path}/state)
if [ "$state3" != "offline" ]; then
    echo "adsp FAIL"
	info_msg "adsp TEST FAILED."
	report_fail "${TCID}"
    exit 1
fi

# Execute command 4 (no output expected)
echo start > ${remoteproc_path}/state

# Execute command 5 and check if the output is "running"
state5=$(cat ${remoteproc_path}/state)
if [ "$state5" != "running" ]; then
    echo "adsp FAIL"
	info_msg "adsp TEST FAILED."
	report_fail "${TCID}"
    exit 1
fi

# If all checks pass, print "PASS"
echo "adsp PASS"
info_msg "adsp TEST PASSED."
report_pass "${TCID}"
