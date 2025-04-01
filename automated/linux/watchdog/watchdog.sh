#!/bin/sh

. automated/lib/sh-test-lib

OUTPUT="$(pwd)/automated/linux/watchdog/output"
RESULT_FILE="${OUTPUT}/result.txt"
export RESULT_FILE


create_out_dir "${OUTPUT}"
TCID="WATCHDOG_Test"

if [ -e /dev/watchdog ]; then
  echo "/dev/watchdog node is present."
  report_pass "${TCID}"
else
  echo "/dev/watchdog node is not present."
  report_fail "${TCID}"
fi