#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Qualcomm Technologies, Inc. and/or its subsidiaries.
#
# Secure video with protected buffers on OP-TEE over FF-A (see
# tee-protmem.c for the cases): installs the secvid TA, runs tee-protmem
# on the stream in ./data and checks that the host logged no oops. Needs
# root, OP-TEE with CFG_CORE_DYN_PROTMEM=y and Linux with the TEE
# protected-memory heap and /proc/kcore.

# shellcheck disable=SC1091
. ../../lib/sh-test-lib
OUTPUT="$(pwd)/output"
RESULT_FILE="${OUTPUT}/result.txt"
ROUNDS="50"

while getopts "r:h" o; do
    case "$o" in
        r) ROUNDS="${OPTARG}" ;;
        h|*) echo "Usage: $0 [-r <eviction rounds>]" 1>&2; exit 1 ;;
    esac
done
export RESULT_FILE
TA_DIR="/lib/optee_armtz"
TA="1b7d45ae-0f97-4ee8-bdeb-f05a852de180.ta"

create_out_dir "${OUTPUT}"
for f in ./tee-protmem "./ta/${TA}" ./data/stream.enc; do
    [ -f "${f}" ] || { info_msg "missing ${f}"; report_fail "prerequisites"; exit 0; }
done
report_pass "prerequisites"
info_msg "cmdline: $(cat /proc/cmdline)"
ls -l /dev/dma_heap/ /dev/tee* || true
cp "./ta/${TA}" "${TA_DIR}/"
grep -qsx tee-supplicant /proc/[0-9]*/comm || info_msg "tee-supplicant is not running"
DMESG0="$(dmesg | wc -l)"
./tee-protmem ./data "${ROUNDS}" 2> "${OUTPUT}/tee-protmem.log" | tee -a "${RESULT_FILE}"
cat "${OUTPUT}/tee-protmem.log"
# tee-protmem stops at a setup error: no case may go unreported.
for c in heap-present protected-alloc protected-mmap-denied system-mmap \
         system-register-fd-refused protected-register-fd ta-refuses-ns-output \
         secure-decrypt protected-host-read-hidden kcore-scan-control \
         protected-data-intact protected-data-evict; do
    grep -q "^${c} " "${RESULT_FILE}" || report_fail "${c}"
done
dmesg | tail -n "+$((DMESG0 + 1))"
if dmesg | tail -n "+$((DMESG0 + 1))" | grep -E -q "Unable to handle kernel|Internal error:|Call trace:"; then
    report_fail "host-no-oops"
else
    report_pass "host-no-oops"
fi
rm -f "${TA_DIR:?}/${TA}"
