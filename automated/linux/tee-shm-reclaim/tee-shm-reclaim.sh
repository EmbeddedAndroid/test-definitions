#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Qualcomm Technologies, Inc. and/or its subsidiaries.
#
# Register, release and re-register TEE shared memory (see
# tee-shm-reclaim.c) and check that the kernel logged no failed reclaim.
#
# The helper is taken from -b, else the installed tee-shm-reclaim
# (qcom-buildroot tee_shm_reclaim_ext), else a copy next to this script,
# else it is built here when the target has a compiler. Without /dev/tee0,
# without a helper, or when the TEE cannot register user memory (OP-TEE
# without dynamic shared memory), every case is skipped with the reason.

# shellcheck disable=SC1091
. ../../lib/sh-test-lib
OUTPUT="$(pwd)/output"
RESULT_FILE="${OUTPUT}/result.txt"
export RESULT_FILE
ROUNDS="20"
PAGES="1 64 1024"
MIN_RANGES="300"
TRANSPORT="any"
BIN=""

usage() {
    echo "Usage: $0 [-r <rounds>] [-p \"<pages> ...\"] [-m <min ranges>] [-t <any|ffa>]" 1>&2
    echo "          [-b <tee-shm-reclaim binary>]" 1>&2
    exit 1
}

while getopts "r:p:m:t:b:h" o; do
  case "$o" in
    r) ROUNDS="${OPTARG}" ;;
    p) PAGES="${OPTARG}" ;;
    m) MIN_RANGES="${OPTARG}" ;;
    t) TRANSPORT="${OPTARG}" ;;
    b) BIN="${OPTARG}" ;;
    h|*) usage ;;
  esac
done

create_out_dir "${OUTPUT}"

# skip_rest <reason>: every case not reported yet is skipped.
skip_rest() {
    warn_msg "$1"
    report_skip "tee-shm-reclaim-open"
    for p in ${PAGES}; do
        report_skip "tee-shm-reclaim-${p}p"
    done
    report_skip "tee-shm-reclaim-no-reclaim-error"
    exit 0
}

skip_all() {
    if [ "${TRANSPORT}" = "ffa" ]; then
        report_skip "tee-shm-reclaim-ffa-transport"
    fi
    skip_rest "$1"
}

[ -c /dev/tee0 ] || skip_all "no /dev/tee0: no TEE driver bound"

if [ -z "${BIN}" ]; then
    if command -v tee-shm-reclaim > /dev/null; then
        BIN="$(command -v tee-shm-reclaim)"
    elif [ -x ./tee-shm-reclaim ]; then
        BIN="./tee-shm-reclaim"
    elif command -v cc > /dev/null && command -v make > /dev/null; then
        make CC=cc > "${OUTPUT}/build.log" 2>&1 || cat "${OUTPUT}/build.log"
        [ -x ./tee-shm-reclaim ] && BIN="./tee-shm-reclaim"
    fi
fi
if [ -z "${BIN}" ] || [ ! -x "${BIN}" ]; then
    skip_all "no tee-shm-reclaim binary (not installed, none next to the script, no compiler)"
fi
info_msg "helper ${BIN}"

if [ "${TRANSPORT}" = "ffa" ]; then
    # The OP-TEE driver binds to an FF-A partition only over FF-A.
    bound=1
    for d in /sys/bus/arm_ffa/devices/*/driver; do
        [ -e "${d}" ] && bound=0
    done
    [ "${bound}" -eq 0 ]
    check_return "tee-shm-reclaim-ffa-transport"
fi

before="$(dmesg | grep -c 'mem_reclaim:')"
# shellcheck disable=SC2086
"${BIN}" "${ROUNDS}" "${MIN_RANGES}" ${PAGES} > "${OUTPUT}/log.txt" 2>&1
rc=$?
cat "${OUTPUT}/log.txt"
if [ "${rc}" -eq 77 ]; then
    skip_rest "the TEE cannot register user memory: no dynamic shared memory"
fi
grep -E '^tee-shm-reclaim-[a-z0-9-]+ (pass|fail)$' "${OUTPUT}/log.txt" >> "${RESULT_FILE}"
# A case the helper did not report (it crashed or stopped early) fails.
grep -q '^tee-shm-reclaim-open ' "${OUTPUT}/log.txt" || report_fail "tee-shm-reclaim-open"
for p in ${PAGES}; do
    grep -q "^tee-shm-reclaim-${p}p " "${OUTPUT}/log.txt" || report_fail "tee-shm-reclaim-${p}p"
done
after="$(dmesg | grep -c 'mem_reclaim:')"
dmesg | grep 'mem_reclaim:' | tail -5
[ "${after}" -eq "${before}" ]
check_return "tee-shm-reclaim-no-reclaim-error"
exit 0
