#!/bin/sh

. automated/lib/sh-test-lib
OUTPUT="$(pwd)/automated/linux/qcrypto/output"
RESULT_FILE="${OUTPUT}/result.txt"

export RESULT_FILE

create_out_dir "${OUTPUT}"

TCID="Kcapi_Test"

cp -r /kcapi/kcapi-convience /usr/bin/

chmod 777 /usr/bin/kcapi-convience

/usr/bin/kcapi-convience

echo $?

if [ $? -eq 0 ]; then
  echo "Test Passed: Exit status is 0"
  info_msg "TEST PASSED."
    report_pass "${TCID}"
else
  echo "Test Failed: Exit status is $?"
  info_msg "TEST FAILED."
  report_fail "${TCID}"
fi