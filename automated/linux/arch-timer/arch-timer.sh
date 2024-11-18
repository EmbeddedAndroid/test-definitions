#!/bin/sh -e
# shellcheck disable=SC1091

HOST_OUTPUT="$(pwd)/output"
RESULT_FILE="${HOST_OUTPUT}/result.txt"
export RESULT_FILE


# shellcheck disable=SC1091
. ../../lib/sh-test-lib
# shellcheck disable=SC1091
. ../../lib/android-test-lib

sudo mkdir -p "${HOST_OUTPUT}"

ls -ltrh
# adb_push "./device-script-arch-timer.sh" "/var/persist"

info_msg "About to run arch timer test on device"
sh /var/persist/device-script-arch-timer.sh | tee "${RESULT_FILE}"
