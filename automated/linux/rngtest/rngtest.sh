#!/bin/sh

. automated/lib/sh-test-lib
OUTPUT="$(pwd)/automated/linux/rngtest/output"
RESULT_FILE="${OUTPUT}/result.txt"

export RESULT_FILE

create_out_dir "${OUTPUT}"

TCID="RNG_Test"

chmod -R 777 /rngtest

cd /rngtest

cat /dev/random | rngtest -c 1000 > /tmp/rngtest_output.txt

grep 'count of bits' /tmp/rngtest_output.txt | awk '{print $NF}' > /tmp/rngtest_value.txt

value=$(cat /tmp/rngtest_value.txt)

if [ "$value" -lt 10 ]; then
  echo "Test Passed: Value is less than 10";
  info_msg "TEST PASSED."
  report_pass "${TCID}"
else
  echo "Test Failed: Value is $value";
  info_msg "TEST FAILED."
  report_fail "${TCID}"
fi