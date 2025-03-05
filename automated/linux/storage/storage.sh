#!/bin/sh

. automated/lib/sh-test-lib
OUTPUT="$(pwd)/automated/linux/storage/output"
RESULT_FILE="${OUTPUT}/result.txt"
export RESULT_FILE

# Run the dd command to create a file with random data
dd if=/dev/random of=/tmp/a.txt bs=1M count=1024
TCID="Storage_Test"

create_out_dir "${OUTPUT}"

# Check if the file is created
if [ -f /tmp/a.txt ]; then
    echo "File /tmp/a.txt is created."

    # Check if the file is not empty
    if [ -s /tmp/a.txt ]; then
        echo "File /tmp/a.txt is not empty. Test Passed" | tee "${RESULT_FILE}"
        report_pass "${TCID}"
    else
        echo "File /tmp/a.txt is empty. Test Failed." | tee "${RESULT_FILE}"
        report_fail "${TCID}"
    fi
else
    echo "File /tmp/a.txt is not created. Test Failed." | tee "${RESULT_FILE}"
    report_fail "${TCID}"
fi