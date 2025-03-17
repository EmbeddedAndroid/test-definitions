#!/bin/sh

. automated/lib/sh-test-lib

OUTPUT="$(pwd)/automated/linux/cdsp/output"
RESULT_FILE="${OUTPUT}/result.txt"
export RESULT_FILE

create_out_dir "${OUTPUT}"
TCID="CDSP_Test"

# Get the firmware output and find the position of cdsp
firmware_output=$(cat /sys/class/remoteproc/remoteproc*/firmware)
cdsp_position=$(echo "$firmware_output" | grep -n "cdsp" | cut -d: -f1)

# Adjust the position to match the remoteproc numbering (starting from 0)
remoteproc_number=$((cdsp_position - 1))

# Construct the remoteproc path based on the cdsp position
remoteproc_path="/sys/class/remoteproc/remoteproc${remoteproc_number}"

# Execute command 1 and check if the output is "running"
state1=$(cat ${remoteproc_path}/state)
if [ "$state1" != "running" ]; then
    echo "cdsp FAIL"
	info_msg "cdsp TEST FAILED."
	report_fail "${TCID}"
    exit 1
fi

# Execute command 2 (no output expected)
echo stop > ${remoteproc_path}/state

# Execute command 3 and check if the output is "offline"
state3=$(cat ${remoteproc_path}/state)
if [ "$state3" != "offline" ]; then
    echo "cdsp FAIL"
	info_msg "cdsp TEST FAILED."
	report_fail "${TCID}"
    exit 1
fi

# Execute command 4 (no output expected)
echo start > ${remoteproc_path}/state

# Execute command 5 and check if the output is "running"
state5=$(cat ${remoteproc_path}/state)
if [ "$state5" != "running" ]; then
    echo "cdsp FAIL"
	info_msg "cdsp TEST FAILED."
	report_fail "${TCID}"
    exit 1
fi

# If all checks pass, print "PASS"
echo "cdsp PASS"
info_msg "cdsp TEST PASSED."
report_pass "${TCID}"
