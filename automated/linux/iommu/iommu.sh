#!/bin/sh

. automated/lib/sh-test-lib
OUTPUT="$(pwd)/automated/linux/iommu/output"
RESULT_FILE="${OUTPUT}/result.txt"

export RESULT_FILE

create_out_dir "${OUTPUT}"

TCID="IOMMU_Test"

# Run the command and capture the output
OUTPUT=$(dmesg | grep iommu)

# Check if the output is null
if [ -z "$OUTPUT" ]; then
    echo "Test failed: No iommu entries found in dmesg" | tee "${RESULT_FILE}"
    report_fail "${TCID}"
else
    echo "Test passed: iommu entries found in dmesg" | tee "${RESULT_FILE}"
    report_pass "${TCID}"
fi