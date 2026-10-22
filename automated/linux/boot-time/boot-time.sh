#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Qualcomm Technologies, Inc. and/or its subsidiaries.
#
# Boot time measured on the target, in seconds from the kernel's time zero
# (the zero of its log time stamps, set in time_init()):
# - pre-kernel: the Arm generic timer's virtual count (CNTVCT_EL0 /
#   CNTFRQ_EL0) at a kernel log line cntvct-arm64 writes, minus that line's
#   time stamp: the time from the counter's zero to the kernel's time zero
#   (the firmware and the kernel's early setup), where the counter starts
#   at zero on reset and runs on (see README.md). It is skipped when the
#   kernel did not start at EL2 or runs under KVM (a hypervisor may offset
#   the virtual counter), when CNTFRQ_EL0 is not set or not the rate the
#   kernel uses, when the counter cannot be read and when the counter is
#   behind the kernel clock (reset or started after the kernel).
# - kernel-to-init: the kernel log time of "Run <init> as init process".
# - kernel-to-login: the start time of the process init started for this
#   session (the getty that printed the login prompt and became login and
#   the shell), moved from CLOCK_BOOTTIME to the kernel log clock with the
#   CLOCK_BOOTTIME the same line carries.

# shellcheck disable=SC1091
. ../../lib/sh-test-lib
OUTPUT="$(pwd)/output"
RESULT_FILE="${OUTPUT}/result.txt"
export RESULT_FILE
DMESG="${OUTPUT}/dmesg.txt"
TOOL=""

usage() {
    echo "Usage: $0 [-t <cntvct binary>]" 1>&2
    exit 1
}

while getopts "t:h" o; do
    case "$o" in
        t) TOOL="${OPTARG}" ;;
        h|*) usage ;;
    esac
done

if [ -z "${TOOL}" ]; then
    case "$(uname -m)" in
        aarch64|arm64) TOOL="./cntvct-arm64" ;;
    esac
fi

create_out_dir "${OUTPUT}"

# "<log time> <CNTVCT_EL0> <CNTFRQ_EL0> <CLOCK_BOOTTIME ns>". CLOCK_BOOTTIME
# runs on jiffies until clocksource_done_booting() and falls behind the log
# clock by the ticks lost until then, so only the log clock is a common zero.
[ -z "${TOOL}" ] || "${TOOL}" || info_msg "${TOOL} failed"
dmesg > "${DMESG}"
mark=$(sed -n 's/^[^[]*\[ *\([0-9]*\.[0-9]*\)\].* boot-time: \([0-9]* [0-9]* [0-9]*\)$/\1 \2/p' "${DMESG}" | tail -n 1)
info_msg "log time, CNTVCT_EL0, CNTFRQ_EL0, CLOCK_BOOTTIME(ns): ${mark}"

# Prints the pre-kernel time, or why it cannot be measured and returns 1.
pre_kernel() {
    if [ -z "${mark}" ]; then
        echo "no timestamped boot-time line in the kernel log (${TOOL:-no tool for $(uname -m)})"
        return 1
    fi
    if ! grep -q "CPU: All CPU(s) started at EL2" "${DMESG}"; then
        echo "the kernel log does not show all CPUs started at EL2, so a hypervisor may offset the virtual counter"
        return 1
    fi
    # A KVM guest with nested virtualization starts at a virtual EL2.
    if grep -q "smccc: KVM: hypervisor services detected" "${DMESG}"; then
        echo "the kernel runs under KVM, which offsets the virtual counter"
        return 1
    fi
    # The rate the kernel counts with: a devicetree clock-frequency
    # overrides CNTFRQ_EL0.
    mhz=$(grep -oE "arch_timer: cp15 (and mmio )?timer(\(s\))? running at [0-9]+\.[0-9]+MHz" "${DMESG}" |
        head -n 1 | sed 's/.* at //; s/MHz//')
    if [ -z "${mhz}" ]; then
        echo "no arch_timer rate line in the kernel log"
        return 1
    fi
    echo "${mark} ${mhz}" | awk '
        $3 == 0 { print "CNTFRQ_EL0 is 0: the counter frequency was not set"; exit 1 }
        int($3 / 10000) != int($5 * 100 + 0.5) { print "CNTFRQ_EL0 (" $3 " Hz) is not the rate the kernel uses (" $5 " MHz)"; exit 1 }
        $2 / $3 < $1 { print "the counter is behind the kernel clock: it was reset or started after the kernel"; exit 1 }
        { printf "%.3f\n", $2 / $3 - $1 }'
}

if t=$(pre_kernel); then
    add_metric pre-kernel pass "${t}" s
else
    info_msg "pre-kernel: ${t}"
    report_skip pre-kernel
fi

t=$(sed -n 's/^[^[]*\[ *\([0-9]*\.[0-9]*\)\].* Run .* as init process$/\1/p' "${DMESG}" | head -n 1)
if [ -n "${t}" ]; then
    add_metric kernel-to-init pass "${t}" s
else
    info_msg "kernel-to-init: no timestamped \"Run <init> as init process\" line in the kernel log"
    report_skip kernel-to-init
fi

# Walk up to the process whose parent is init. Its start time (field 22 of
# /proc/<pid>/stat) is in USER_HZ ticks of CLOCK_BOOTTIME, 100 per second on
# arm64.
pid=$$
while stat=$(cat "/proc/${pid}/stat" 2>/dev/null); do
    # shellcheck disable=SC2086
    set -- ${stat##*) }
    [ "$2" -gt 1 ] || break
    pid=$2
done
if [ -z "${mark}" ]; then
    info_msg "kernel-to-login: no CLOCK_BOOTTIME reading in the kernel log to place the start time on the log clock"
    report_skip kernel-to-login
elif [ "$2" = 1 ]; then
    shift 19
    info_msg "session started by init: pid ${pid} ($(cat "/proc/${pid}/comm")), CLOCK_BOOTTIME $1 ticks"
    add_metric kernel-to-login pass "$(echo "$1 ${mark}" | awk '{ printf "%.2f\n", $1 / 100 + $2 - $5 / 1e9 }')" s
else
    info_msg "kernel-to-login: no process of this session was started by init"
    report_skip kernel-to-login
fi
exit 0
