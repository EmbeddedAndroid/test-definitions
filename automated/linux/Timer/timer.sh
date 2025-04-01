#!/bin/sh

. automated/lib/sh-test-lib
OUTPUT="$(pwd)/automated/linux/Timer/output"
RESULT_FILE="${OUTPUT}/result.txt"

export RESULT_FILE

create_out_dir "${OUTPUT}"

TCID="Timer_Test"

chmod -R 777 /APT/timers

# Path to the binary
BINARY_PATH="/APT/timers/posix_timers"

# Run the binary and capture the output
OUTPUT=$($BINARY_PATH)

# Check if "pass:7" is in the output
if [[ $OUTPUT == *"pass:7"* ]]; then
    echo "Test passed"
	info_msg "TEST PASSED."
    report_pass "${TCID}"
else
    echo "Test Failed"
	info_msg "TEST FAILED."
    report_fail "${TCID}"
fi