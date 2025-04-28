#!/bin/sh

. automated/lib/sh-test-lib

OUTPUT="$(pwd)/automated/linux/KASLR/output"
RESULT_FILE="${OUTPUT}/result.txt"
export RESULT_FILE

create_out_dir "${OUTPUT}"
TCID="KASLR_Test"


output=$(cat /proc/kallsyms | grep stext)


value=$(echo $output | awk '{print $1}')


if [[ $value != "0000000000000000" ]]; then
    echo "kaslr PASS"
	info_msg "kaslr TEST PASSED."
	report_pass "${TCID}"
else
    echo "kaslr FAIL"
	info_msg "kaslr TEST FAILED."
	report_fail "${TCID}"
fi
