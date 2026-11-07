#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Qualcomm Technologies, Inc. and/or its subsidiaries.
#
# Health of the Xen control domain (dom0): its vCPUs against the host's
# CPUs, the grant table, the hvc0 console, event channels, and a kernel log
# and Xen console ring without Xen specific errors. Skipped without Xen.

# shellcheck disable=SC1091
. ../../lib/sh-test-lib
# shellcheck disable=SC1091
. ./xen-lib.sh
OUTPUT="$(pwd)/output"
RESULT_FILE="${OUTPUT}/result.txt"
export RESULT_FILE

DOM0_VCPUS=""
IGNORE=""

usage() {
    echo "Usage: $0 [-c <dom0 vCPUs>] [-i <ignore regex>]" 1>&2
    exit 1
}

while getopts "c:i:h" o; do
    case "$o" in
        c) DOM0_VCPUS="${OPTARG}" ;;
        i) IGNORE="${OPTARG}" ;;
        h|*) usage ;;
    esac
done

create_out_dir "${OUTPUT}"

CASES="dom0-vcpus grant-table hvc0-console event-channels dom0-log-xen-clean xen-log-clean"
# shellcheck disable=SC2086
xen_require "false" ${CASES}

# dom0's vCPUs: the CPUs Linux counts; the host's: xl info nr_cpus.
vcpus="$(grep -c '^processor' /proc/cpuinfo)"
want="${DOM0_VCPUS}"
if [ -z "${want}" ] && command -v xl > /dev/null; then
    want="$(xl info 2> /dev/null | sed -n 's/^nr_cpus *: *//p')"
fi
info_msg "dom0 vCPUs ${vcpus}, expected ${want:-unknown}"
if [ -z "${want}" ]; then
    warn_msg "no xl and no DOM0_VCPUS: cannot tell how many vCPUs dom0 should have"
    report_skip "dom0-vcpus"
else
    [ "${vcpus}" -eq "${want}" ]
    check_return "dom0-vcpus"
fi

dmesg > "${OUTPUT}/dmesg.txt"
grep -E 'grant_table|Grant table' "${OUTPUT}/dmesg.txt"
grep -q -E 'Grant tables using version [0-9]+ layout' "${OUTPUT}/dmesg.txt"
check_return "grant-table"

grep hvc /proc/consoles
[ -c /dev/hvc0 ] && grep -q '^hvc0 ' /proc/consoles
check_return "hvc0-console"

# Event channels: the FIFO or 2-level ABI is set up and the upcall
# interrupt is registered (on Arm a per-CPU interrupt named "events"; on
# x86 the xen-percpu and xen-dyn chips).
grep -E 'xen:events' "${OUTPUT}/dmesg.txt"
grep -E 'xen-dyn|xen-percpu|[[:space:]]events$' /proc/interrupts | head -5
grep -q -E 'xen:events: Using (FIFO|2-level)' "${OUTPUT}/dmesg.txt" &&
    grep -q -E 'xen-dyn|xen-percpu|[[:space:]]events$' /proc/interrupts
check_return "event-channels"

# Kernel messages of the Xen drivers (xen:*, xenbus, evtchn, grant) that
# report an error, plus any WARNING or BUG whose trace names a xen symbol.
grep -i -E '\] (xen[:_ -]|xenbus|xen_|evtchn|grant)' "${OUTPUT}/dmesg.txt" |
    grep -i -E 'fail|error|warn|unable|cannot|invalid|bug' > "${OUTPUT}/xen-errors.txt"
awk '/(WARNING|BUG):/ { t = 1; b = $0; next }
     t && /---\[ end trace/ { t = 0; next }
     t && /xen/ { print b; print; t = 0 }' "${OUTPUT}/dmesg.txt" >> "${OUTPUT}/xen-errors.txt"
if [ -n "${IGNORE}" ]; then
    grep -v -E "${IGNORE}" "${OUTPUT}/xen-errors.txt" > "${OUTPUT}/xen-errors.kept" || true
    mv "${OUTPUT}/xen-errors.kept" "${OUTPUT}/xen-errors.txt"
fi
cat "${OUTPUT}/xen-errors.txt"
[ ! -s "${OUTPUT}/xen-errors.txt" ]
check_return "dom0-log-xen-clean"

# The Xen console ring: no assertion, BUG, WARN or panic.
if command -v xl > /dev/null; then
    xl dmesg > "${OUTPUT}/xl-dmesg.txt" 2>&1
    grep -E 'Assertion .* failed|Xen BUG at|Xen WARN at|Xen call trace|PANIC' "${OUTPUT}/xl-dmesg.txt" > "${OUTPUT}/xl-errors.txt"
    if [ -n "${IGNORE}" ]; then
        grep -v -E "${IGNORE}" "${OUTPUT}/xl-errors.txt" > "${OUTPUT}/xl-errors.kept" || true
        mv "${OUTPUT}/xl-errors.kept" "${OUTPUT}/xl-errors.txt"
    fi
    cat "${OUTPUT}/xl-errors.txt"
    [ ! -s "${OUTPUT}/xl-errors.txt" ]
    check_return "xen-log-clean"
else
    warn_msg "no xl to read the Xen console ring"
    report_skip "xen-log-clean"
fi
exit 0
