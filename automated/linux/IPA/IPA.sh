#!/bin/sh

. automated/lib/sh-test-lib
OUTPUT="$(pwd)/automated/linux/IPA/output"
RESULT_FILE="${OUTPUT}/result.txt"

export RESULT_FILE

create_out_dir "${OUTPUT}"

TCID="IPA_Test"

PATH=$(find / -name "ipa.ko" 2>/dev/null)

# Check if the file was found
if [ -z "$PATH" ]; then
  echo "ipa.ko file not found."
  exit 1
fi

# Insert the module
insmod "$PATH"

if lsmod | grep -q "ipa"; then
  report_pass "${TCID}"
  echo "Test case passed."
else
  report_fail "${TCID}"
  echo "Test case failed."
fi
