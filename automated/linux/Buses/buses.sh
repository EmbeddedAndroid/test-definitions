#!/bin/sh

. automated/lib/sh-test-lib

OUTPUT="$(pwd)/automated/linux/Buses/output"
RESULT_FILE="${OUTPUT}/result.txt"
export RESULT_FILE


create_out_dir "${OUTPUT}"
TCID="BUSES_Test"

output=$(./i2c-msm-test -v -D /dev/i2c-0 -l | grep "ret:1")


if echo "$output" | grep -q "Reading"; then
  echo "Test case passed."
  report_pass "${TCID}"
else
  echo "Test case failed."
  report_fail "${TCID}"
fi
