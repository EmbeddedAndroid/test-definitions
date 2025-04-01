#!/bin/sh

. automated/lib/sh-test-lib

OUTPUT="$(pwd)/automated/linux/pinctrl/output"
RESULT_FILE="${OUTPUT}/result.txt"
export RESULT_FILE

# Execute the command and store the output
output=$(ls /sys/kernel/debug/pinctrl)

create_out_dir "${OUTPUT}"
TCID="SOC_Pinctrl_Test"

# Check if the output is empty
if [ -z "$output" ]; then
	echo "pinctrl FAIL"
	report_fail "${TCID}"
else
	echo "pinctrl PASS"
	report_pass "${TCID}"
fi