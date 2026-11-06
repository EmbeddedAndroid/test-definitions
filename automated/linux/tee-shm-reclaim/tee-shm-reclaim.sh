#!/bin/sh
# Register, release and re-register TEE shared memory (see
# tee-shm-reclaim.c) and check that the kernel logged no failed reclaim.

. ../../lib/sh-test-lib
OUTPUT="$(pwd)/output"
RESULT_FILE="${OUTPUT}/result.txt"
ROUNDS="20"
PAGES="1 64 1024"
MIN_RANGES="300"
TRANSPORT="any"

usage() {
    echo "Usage: $0 [-r <rounds>] [-p \"<pages> ...\"] [-m <min ranges>] [-t <any|ffa>]" 1>&2
    exit 1
}

while getopts "r:p:m:t:h" o; do
  case "$o" in
    r) ROUNDS="${OPTARG}" ;;
    p) PAGES="${OPTARG}" ;;
    m) MIN_RANGES="${OPTARG}" ;;
    t) TRANSPORT="${OPTARG}" ;;
    h|*) usage ;;
  esac
done

create_out_dir "${OUTPUT}"

if [ "${TRANSPORT}" = "ffa" ]; then
    # The OP-TEE driver binds to an FF-A partition only over FF-A.
    ls /sys/bus/arm_ffa/devices/*/driver 2>/dev/null | grep -q .
    check_return "tee-shm-reclaim-ffa-transport"
fi

[ -x ./tee-shm-reclaim ]
exit_on_fail "tee-shm-reclaim-binary"

before="$(dmesg | grep -c 'mem_reclaim:')"
# shellcheck disable=SC2086
./tee-shm-reclaim "${ROUNDS}" "${MIN_RANGES}" ${PAGES} 2>&1 | tee "${OUTPUT}/log.txt"
grep -E '^tee-shm-reclaim-[a-z0-9-]+ (pass|fail)$' "${OUTPUT}/log.txt" >> "${RESULT_FILE}"
after="$(dmesg | grep -c 'mem_reclaim:')"
dmesg | grep 'mem_reclaim:' | tail -5
[ "${after}" -eq "${before}" ]
check_return "tee-shm-reclaim-no-reclaim-error"
