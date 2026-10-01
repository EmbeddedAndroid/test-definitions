#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Qualcomm Technologies, Inc. and/or its subsidiaries.
#
# Drive every cpufreq policy to its lowest and highest available frequency
# with the userspace governor and check that the hardware reports the
# requested frequency back. Then load all online CPUs with stress-ng under
# the policy's own governor and check that the frequency scales up and the
# load completes. Policies without an online CPU are skipped.

# shellcheck disable=SC1091
. ../../lib/sh-test-lib
OUTPUT="$(pwd)/output"
RESULT_FILE="${OUTPUT}/result.txt"
export RESULT_FILE

ONLINE_ALL="false"
STRESS_SECONDS="60"
SETTLE_SECONDS="1"

usage() {
    echo "Usage: $0 [-o <true|false>] [-s <stress seconds, 0 to skip>] [-w <settle seconds>]" 1>&2
    exit 1
}

while getopts "o:s:w:h" o; do
    case "$o" in
        o) ONLINE_ALL="${OPTARG}" ;;
        s) STRESS_SECONDS="${OPTARG}" ;;
        w) SETTLE_SECONDS="${OPTARG}" ;;
        h|*) usage ;;
    esac
done

SYS_CPU=/sys/devices/system/cpu

cur_freq() {
    cat "$1/cpuinfo_cur_freq" 2>/dev/null || cat "$1/scaling_cur_freq"
}

show() {
    info_msg "online $(cat ${SYS_CPU}/online), offline $(cat ${SYS_CPU}/offline)"
    for p in "${SYS_CPU}"/cpufreq/policy*; do
        [ -d "${p}" ] || continue
        info_msg "$(basename "${p}"): related $(cat "${p}/related_cpus"), affected $(cat "${p}/affected_cpus"), governor $(cat "${p}/scaling_governor"), cur $(cur_freq "${p}")"
    done
}

# drive <policy dir>: lowest and highest frequency under userspace
drive() {
    local p="$1"
    local name
    local freqs
    local lo
    local hi
    local old
    local r
    name="$(basename "${p}")"
    if [ -z "$(cat "${p}/affected_cpus")" ]; then
        info_msg "${name}: no online CPU"
        report_skip "${name}-min"
        report_skip "${name}-max"
        return
    fi
    if ! grep -qw userspace "${p}/scaling_available_governors" ||
       [ ! -r "${p}/scaling_available_frequencies" ]; then
        info_msg "${name}: no userspace governor or frequency table"
        report_skip "${name}-min"
        report_skip "${name}-max"
        return
    fi
    freqs="$(tr ' ' '\n' < "${p}/scaling_available_frequencies" | grep -E '^[0-9]+$' | sort -n)"
    lo="$(echo "${freqs}" | head -n 1)"
    hi="$(echo "${freqs}" | tail -n 1)"
    old="$(cat "${p}/scaling_governor")"
    echo userspace > "${p}/scaling_governor"
    for t in min:"${lo}" max:"${hi}"; do
        echo "${t#*:}" > "${p}/scaling_setspeed"
        sleep "${SETTLE_SECONDS}"
        r="$(cur_freq "${p}")"
        info_msg "${name}: set ${t#*:} read ${r}"
        if [ "${r}" = "${t#*:}" ]; then
            add_metric "${name}-${t%%:*}" "pass" "${r}" "kHz"
        else
            add_metric "${name}-${t%%:*}" "fail" "${r}" "kHz"
        fi
    done
    echo "${old}" > "${p}/scaling_governor"
}

create_out_dir "${OUTPUT}"

if ! ls -d "${SYS_CPU}"/cpufreq/policy* > /dev/null 2>&1; then
    info_msg "no cpufreq policy"
    report_skip "cpufreq-policies"
    exit 0
fi
report_pass "cpufreq-policies"

if [ "${ONLINE_ALL}" = "true" ] || [ "${ONLINE_ALL}" = "True" ]; then
    for c in "${SYS_CPU}"/cpu[0-9]*; do
        [ -f "${c}/online" ] || continue
        [ "$(cat "${c}/online")" = 1 ] || echo 1 > "${c}/online" || info_msg "$(basename "${c}") did not come online"
    done
fi

show
for p in "${SYS_CPU}"/cpufreq/policy*; do
    drive "${p}"
done

if [ "${STRESS_SECONDS}" -eq 0 ]; then
    exit 0
fi
if ! command -v stress-ng > /dev/null; then
    warn_msg "stress-ng is not installed"
    report_skip "stress-ng-load"
    exit 0
fi

# Sample every policy once a second while all online CPUs are loaded and
# keep the highest frequency each one reached.
LOG="${OUTPUT}/stress-ng.log"
stress-ng --cpu 0 --timeout "${STRESS_SECONDS}s" --metrics-brief > "${LOG}" 2>&1 &
pid=$!
i=0
while kill -0 "${pid}" 2> /dev/null && [ "${i}" -lt $((STRESS_SECONDS + 30)) ]; do
    sleep 1
    i=$((i + 1))
    for p in "${SYS_CPU}"/cpufreq/policy*; do
        [ -n "$(cat "${p}/affected_cpus")" ] || continue
        f="$(cur_freq "${p}")"
        n="$(basename "${p}")"
        m="$(cat "${OUTPUT}/${n}.peak" 2>/dev/null || echo 0)"
        [ "${f}" -gt "${m}" ] && echo "${f}" > "${OUTPUT}/${n}.peak"
    done
done
if kill -0 "${pid}" 2> /dev/null; then
    kill "${pid}"
    wait "${pid}"
    info_msg "stress-ng still running after $((STRESS_SECONDS + 30)) s"
    report_fail "stress-ng-load"
else
    wait "${pid}"
    check_return "stress-ng-load"
fi
cat "${LOG}"

for p in "${SYS_CPU}"/cpufreq/policy*; do
    n="$(basename "${p}")"
    [ -r "${OUTPUT}/${n}.peak" ] || continue
    lo="$(tr ' ' '\n' < "${p}/scaling_available_frequencies" | grep -E '^[0-9]+$' | sort -n | head -n 1)"
    peak="$(cat "${OUTPUT}/${n}.peak")"
    info_msg "${n}: peak ${peak} under load, lowest ${lo}"
    if [ "${peak}" -gt "${lo}" ]; then
        add_metric "${n}-scales-under-load" "pass" "${peak}" "kHz"
    else
        add_metric "${n}-scales-under-load" "fail" "${peak}" "kHz"
    fi
done
show
exit 0
