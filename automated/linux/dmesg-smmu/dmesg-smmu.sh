#!/bin/sh -e
# shellcheck disable=SC1091

HOST_OUTPUT="$(pwd)/output"
RESULT_FILE="${HOST_OUTPUT}/result.txt"
export RESULT_FILE


# shellcheck disable=SC1091
. ../../lib/sh-test-lib
# shellcheck disable=SC1091
. ../../lib/android-test-lib

mkdir -p "${HOST_OUTPUT}"

ls -ltrh

info_msg "About to run dmesg-smmu test on device"
sh device-script-dmesg-smmu.sh | tee "${RESULT_FILE}"
