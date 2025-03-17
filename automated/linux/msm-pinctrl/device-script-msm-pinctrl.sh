#!/bin/sh

. automated/lib/sh-test-lib

OUTPUT="$(pwd)/automated/linux/msm-pinctrl/output"
RESULT_FILE="${OUTPUT}/result.txt"
export RESULT_FILE

# Execute the command and store the output
output=$(ls /sys/kernel/debug/pinctrl)

create_out_dir "${OUTPUT}"
TCID="MSM_Pinctrl_Test"

# Check if the output is empty
if [ -z "$output" ]; then
	echo "msm-pinctrl FAIL"
	report_fail "${TCID}"
else
	echo "msm-pinctrl PASS"
	report_pass "${TCID}"
fi