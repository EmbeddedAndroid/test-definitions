#!/bin/sh

. automated/lib/sh-test-lib

OUTPUT="$(pwd)/automated/linux/cpufreq/output"
RESULT_FILE="${OUTPUT}/result.txt"
export RESULT_FILE


create_out_dir "${OUTPUT}"
TCID="CPU_RAMPUP_RAMPDOWN_Test"

SCRIPT_PATH="/APT/cpufreq/main.sh"


res=$($SCRIPT_PATH)


if echo "$res" | grep -q "PASS"; then
  echo "Test case passed."
  report_pass "${TCID}"
else
  echo "Test case failed"
  report_fail "${TCID}"
fi
