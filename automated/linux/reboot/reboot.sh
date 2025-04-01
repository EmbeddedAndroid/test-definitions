#!/bin/sh

. automated/lib/sh-test-lib

OUTPUT="$(pwd)/automated/linux/reboot/output"
RESULT_FILE="${OUTPUT}/result.txt"
export RESULT_FILE

reboot

sleep 120

# Execute the command and store the output
op=$(ls)

create_out_dir "${OUTPUT}"
TCID="Reboot_Test"

# Check if the output is empty
if [ -z "$op" ]; then
	echo "pinctrl FAIL"
	report_fail "${TCID}"
else
	echo "pinctrl PASS"
	report_pass "${TCID}"
fi