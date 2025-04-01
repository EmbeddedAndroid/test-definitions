#!/bin/sh

. automated/lib/sh-test-lib
OUTPUT="$(pwd)/automated/linux/RMNET/output"
RESULT_FILE="${OUTPUT}/result.txt"

export RESULT_FILE

create_out_dir "${OUTPUT}"

TCID="RMNET_Test"

PATH=$(find / -name "rmnet.ko" 2>/dev/null)

if [ -z "$PATH" ]; then
  echo "rmnet.ko file not found."
  exit 1
fi

insmod "$PATH"

if lsmod | grep -q "ipa"; then
  report_pass "${TCID}"
  echo "Test case passed."
else
  report_fail "${TCID}"
  echo "Test case failed."
fi
