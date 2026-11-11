#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Qualcomm Technologies, Inc. and/or its subsidiaries.
#
# Iris secure decode and encode in protected buffers under pKVM (see
# iris-secure.c for the cases): installs the secvid TA (from tee-protmem),
# records the hypervisor's SMMU setup, runs iris-secure on ./data and
# checks that the host logged no oops. Needs root, OP-TEE with
# CFG_CORE_DYN_PROTMEM=y and CFG_CACHE_API=y, and Linux with the TEE
# protected heap, the iris secure sessions and CONFIG_ARM_SMMU_PKVM.

# shellcheck disable=SC1091
. ../../lib/sh-test-lib
# In RAM: the results must survive a DMA fault that stalls the storage
OUTPUT="/tmp/iris-secure/output"
RESULT_FILE="${OUTPUT}/result.txt"
MIN_PSNR="30"
WATCHDOG="600"
# Storage behind the same SMMU, read after the codec faulted
STORAGE="/dev/mmcblk0"

while getopts "p:w:s:h" o; do
    case "$o" in
        p) MIN_PSNR="${OPTARG}" ;;
        w) WATCHDOG="${OPTARG}" ;;
        s) STORAGE="${OPTARG}" ;;
        h|*) echo "Usage: $0 [-p <min psnr>] [-w <watchdog s>] [-s <storage device>]" 1>&2; exit 1 ;;
    esac
done
export RESULT_FILE
TA_DIR="/lib/optee_armtz"
TA="1b7d45ae-0f97-4ee8-bdeb-f05a852de180.ta"

create_out_dir "${OUTPUT}"
for f in ./iris-secure "../tee-protmem/ta/${TA}" ./data/clip.enc; do
    [ -f "${f}" ] || { info_msg "missing ${f}"; report_fail "prerequisites"; exit 0; }
done
report_pass "prerequisites"
info_msg "cmdline: $(cat /proc/cmdline)"
mount -t debugfs none /sys/kernel/debug 2> /dev/null || true
ls -l /dev/dma_heap/ /dev/tee* || true
# The hypervisor owns the shadow and secure banks: the host driver sees fewer
dmesg | grep -E "arm-smmu-pkvm|secure sessions"
if dmesg | grep -q "arm-smmu-pkvm: .* context banks left to the host" &&
   dmesg | grep -q "secure sessions through the hypervisor secure banks"; then
    report_pass "smmu-hyp-banks"
else
    report_fail "smmu-hyp-banks"
fi
cat /sys/kernel/debug/arm_smmu_pkvm || true
cp "../tee-protmem/ta/${TA}" "${TA_DIR}/"
# The kernel log from here on, found by a marker (the ring may wrap)
MARK="iris-secure: start $$ $(date +%s)"
echo "${MARK}" > /dev/kmsg
# Without the marker nothing can be judged: report a crash and an oops,
# so that the checks below fail rather than pass on an empty log.
klog() {
    if dmesg | grep -q "${MARK}"; then
        dmesg | sed -n "/${MARK}/,\$p"
    else
        echo "kernel log wrapped past the marker: crash detected, Call trace: unknown"
    fi
}
# Reads the storage uncached, giving up after 30 s (no timeout(1) on the
# target): it may sit behind a stalled SMMU context.
read_storage() {
    dd if="${STORAGE}" of=/dev/null bs=1M count=16 skip=64 2> /dev/null &
    dpid=$!
    n=0
    while kill -0 "${dpid}" 2> /dev/null && [ "${n}" -lt 30 ]; do
        sleep 1
        n=$((n + 1))
    done
    if kill -0 "${dpid}" 2> /dev/null; then
        kill -9 "${dpid}" 2> /dev/null || true
        return 1
    fi
    wait "${dpid}"
}
# Details stream to the console as they happen; a hung case still leaves
# the blocked tasks' stacks and the kernel log behind.
./iris-secure ./data "${MIN_PSNR}" > "${OUTPUT}/iris-secure.out" 2>&1 &
PID=$!
tail -f "${OUTPUT}/iris-secure.out" &
TAIL=$!
i=0
while kill -0 "${PID}" 2> /dev/null && [ "${i}" -lt "${WATCHDOG}" ]; do
    sleep 1
    i=$((i + 1))
done
if kill -0 "${PID}" 2> /dev/null; then
    info_msg "iris-secure still running after ${WATCHDOG} s"
    dmesg | tail -n 80
    grep -E "^State" "/proc/${PID}/status" 2> /dev/null || true
    cat "/proc/${PID}/stack" 2> /dev/null || true
    # Reading the hypervisor's fault record also clears the shadow bank's
    # fault status: if the hang is a fault left pending there, it resumes.
    cat /sys/kernel/debug/arm_smmu_pkvm || true
    sleep 10
    info_msg "10 s after clearing the shadow bank fault"
    grep -E "^State" "/proc/${PID}/status" 2> /dev/null || true
    cat /sys/kernel/debug/arm_smmu_pkvm || true
    echo w > /proc/sysrq-trigger 2> /dev/null || true
    dmesg | tail -n 60
    kill -9 "${PID}" 2> /dev/null || true
    report_fail "watchdog"
fi
kill "${TAIL}" 2> /dev/null || true
echo "=== iris-secure details"
cat "${OUTPUT}/iris-secure.out"
grep -E "^[a-z-]+ (pass|fail|skip)$" "${OUTPUT}/iris-secure.out" >> "${RESULT_FILE}" || true
for c in ref-decode secure-decode secure-encode nonsecure-protected-refused \
         secure-unprotected-refused hyp-refuses-unlent nonsecure-dma-blocked \
         aimed-dma-host-page hyp-data-dma-read-blocked hyp-data-dma-write-blocked \
         iommu-pool-dma-read-blocked iommu-pool-dma-write-blocked; do
    grep -q "^${c} " "${RESULT_FILE}" || report_fail "${c}"
done
cat /sys/kernel/debug/arm_smmu_pkvm || true
klog
# The codec's faulting DMA must not disturb the other masters behind the
# same SMMU: no DSP crash, no storage error, and storage still reads.
if klog | \
        grep -E -q "crash detected|mmc[0-9]+: (Timeout|running CQE recovery)|ADMA error"; then
    report_fail "other-dma-unaffected"
elif echo 3 > /proc/sys/vm/drop_caches &&
     read_storage; then
    report_pass "other-dma-unaffected"
else
    report_fail "other-dma-unaffected"
fi
if klog | grep -E -q "Unable to handle kernel|Internal error:|Call trace:"; then
    report_fail "host-no-oops"
else
    report_pass "host-no-oops"
fi
rm -f "${TA_DIR:?}/${TA}"
