#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Qualcomm Technologies, Inc. and/or its subsidiaries.
#
# Drive every cpufreq policy to its lowest and highest available frequency
# with the userspace governor. Check that the hardware reports the
# requested frequency back, read with a loop pinned to the policy's first
# CPU (idle if nothing can pin it) and, for the lowest frequency, every other
# policy held at its own lowest, and time a fixed busy loop pinned to one CPU of
# the policy at both frequencies: the runtime ratio must match the
# frequency ratio. Then load all online CPUs with stress-ng under the
# policy's own governor and check that the frequency scales up and the load
# completes. Policies without an online CPU are skipped.

# shellcheck disable=SC1091
. ../../lib/sh-test-lib
OUTPUT="$(pwd)/output"
RESULT_FILE="${OUTPUT}/result.txt"
export RESULT_FILE

ONLINE_ALL="false"
STRESS_SECONDS="60"
SETTLE_SECONDS="1"
# Readbacks per requested frequency, 0.2 s apart; every one must match.
SAMPLES=5
TIMED_NEGATIVE="false"
# Shortest timed run at the highest frequency in /proc/uptime ticks
# (centiseconds), and the allowed deviation of the runtime ratio from the
# frequency ratio in percent.
MIN_TICKS=50
TOLERANCE=15

usage() {
    echo "Usage: $0 [-o <true|false>] [-s <stress seconds, 0 to skip>] [-w <settle seconds>] [-n <true|false>]" 1>&2
    exit 1
}

while getopts "o:s:w:n:h" o; do
    case "$o" in
        o) ONLINE_ALL="${OPTARG}" ;;
        s) STRESS_SECONDS="${OPTARG}" ;;
        w) SETTLE_SECONDS="${OPTARG}" ;;
        n) TIMED_NEGATIVE="${OPTARG}" ;;
        h|*) usage ;;
    esac
done

SYS_CPU=/sys/devices/system/cpu

cur_freq() {
    cat "$1/cpuinfo_cur_freq" 2>/dev/null || cat "$1/scaling_cur_freq"
}

# real_freq <policy dir> <kHz>: whether a reading can be the running
# frequency. Some drivers report a limit instead: qcom-cpufreq-hw with an
# LMh interrupt returns the LMh throttle vote, above cpuinfo_max_freq.
real_freq() {
    if [ "$2" -ge "$(cat "$1/cpuinfo_min_freq")" ] &&
       [ "$2" -le "$(cat "$1/cpuinfo_max_freq")" ]; then
        return 0
    fi
    info_msg "$(basename "$1"): ${2} kHz is outside cpuinfo_min_freq..cpuinfo_max_freq, not the running frequency"
    return 1
}

show() {
    info_msg "online $(cat ${SYS_CPU}/online), offline $(cat ${SYS_CPU}/offline)"
    for p in "${SYS_CPU}"/cpufreq/policy*; do
        [ -d "${p}" ] || continue
        info_msg "$(basename "${p}"): related $(cat "${p}/related_cpus"), affected $(cat "${p}/affected_cpus"), governor $(cat "${p}/scaling_governor"), cur $(cur_freq "${p}")"
    done
}

# The timed loop is pinned with taskset or, where that is missing (as in
# Buildroot's default BusyBox), with a cgroup v2 cpuset.
PIN=""
CPUSET=""
CG_MOUNTED=""
pin_setup() {
    local cg
    if command -v taskset > /dev/null; then
        PIN="taskset"
        return
    fi
    cg="$(awk '$3 == "cgroup2" { print $2; exit }' /proc/mounts)"
    if [ -z "${cg}" ] && ! grep -q " /sys/fs/cgroup " /proc/mounts &&
       mount -t cgroup2 none /sys/fs/cgroup; then
        cg=/sys/fs/cgroup
        CG_MOUNTED="${cg}"
    fi
    if [ -n "${cg}" ] && grep -qw cpuset "${cg}/cgroup.controllers" &&
       echo +cpuset > "${cg}/cgroup.subtree_control" &&
       mkdir -p "${cg}/cpufreq-policy"; then
        CPUSET="${cg}/cpufreq-policy"
        PIN="cpuset"
    fi
}

pin_cleanup() {
    [ -z "${CPUSET}" ] || rmdir "${CPUSET}"
    [ -z "${CG_MOUNTED}" ] || umount "${CG_MOUNTED}"
}

# pinned <cpu> <script> [args]: exec sh -c <script> on <cpu> only. It
# replaces the calling shell, so call it in a subshell ($(...) or &); in
# the background, $! is then the loop itself and kill stops it.
pinned() {
    local cpu="$1"
    local script="$2"
    shift 2
    if [ "${PIN}" = "taskset" ]; then
        exec taskset -c "${cpu}" sh -c "${script}" pinned "$@"
    else
        echo "${cpu}" > "${CPUSET}/cpuset.cpus" || return
        # shellcheck disable=SC2016
        exec sh -c 'echo $$ > "$1/cgroup.procs" || exit 1; shift; eval "$0"' "${script}" "${CPUSET}" "$@"
    fi
}

# busy <cpu> <iterations>: /proc/uptime ticks (centiseconds) a fixed loop
# takes on <cpu>
busy() {
    # shellcheck disable=SC2016
    pinned "$1" '
        s="$(tr -d . < /proc/uptime | cut -d " " -f 1)"
        i=0
        while [ "${i}" -lt "$1" ]; do i=$((i + 1)); done
        e="$(tr -d . < /proc/uptime | cut -d " " -f 1)"
        echo $((e - s))' "$2"
}

# timed <policy dir> <lowest> <highest>: run the busy loop on the policy's
# first online CPU at both frequencies; the runtime ratio must match the
# frequency ratio within TOLERANCE percent
timed() {
    local p="$1"
    local lo="$2"
    local hi="$3"
    local slow="$2"
    local name
    local cpu
    local n=10000
    local t_hi
    local t_lo
    local ratio
    local dev
    name="$(basename "${p}")-runtime-ratio"
    cpu="$(cut -d ' ' -f 1 "${p}/affected_cpus")"
    if [ -z "${PIN}" ]; then
        info_msg "${name}: neither taskset nor a cgroup v2 cpuset to pin the loop"
        report_skip "${name}"
        return
    fi
    if [ "${TIMED_NEGATIVE}" = "true" ] || [ "${TIMED_NEGATIVE}" = "True" ]; then
        info_msg "${name}: negative control, both runs at ${hi} kHz"
        slow="${hi}"
    fi
    echo "${hi}" > "${p}/scaling_setspeed"
    sleep "${SETTLE_SECONDS}"
    t_hi="$(busy "${cpu}" "${n}")"
    while [ -n "${t_hi}" ] && [ "${t_hi}" -lt "${MIN_TICKS}" ]; do
        n=$((n * 2))
        t_hi="$(busy "${cpu}" "${n}")"
    done
    echo "${slow}" > "${p}/scaling_setspeed"
    sleep "${SETTLE_SECONDS}"
    t_lo="$(busy "${cpu}" "${n}")"
    if [ -z "${t_hi}" ] || [ -z "${t_lo}" ]; then
        info_msg "${name}: the loop did not run on cpu${cpu}"
        report_fail "${name}"
        return
    fi
    ratio=$((t_lo * 100 / t_hi))
    ratio="$((ratio / 100)).$(printf '%02d' $((ratio % 100)))"
    dev=$((t_lo * lo * 100 / (t_hi * hi)))
    info_msg "${name}: cpu${cpu}, ${n} iterations: ${t_hi} ticks at ${hi} kHz, ${t_lo} ticks at ${slow} kHz, runtime ratio ${ratio}, ${dev}% of the frequency ratio"
    if [ "${dev}" -ge $((100 - TOLERANCE)) ] && [ "${dev}" -le $((100 + TOLERANCE)) ]; then
        add_metric "${name}" "pass" "${ratio}"
    else
        add_metric "${name}" "fail" "${ratio}"
    fi
}

# hold_low <policy dir>: put every other policy with an online CPU at its
# lowest frequency under userspace, saving its governor in OUTPUT. Domains
# sharing a voltage rail raise each other (EPSS shared-rail boost: on SM8650
# the A720 CPUs 5-6 and the X4 CPU 7 share APC1), so the lowest frequency of
# one domain is only defined while the rail-mates do not need more voltage.
hold_low() {
    local q
    for q in "${SYS_CPU}"/cpufreq/policy*; do
        [ "${q}" != "$1" ] || continue
        [ -n "$(cat "${q}/affected_cpus")" ] || continue
        grep -qw userspace "${q}/scaling_available_governors" || continue
        cat "${q}/scaling_governor" > "${OUTPUT}/$(basename "${q}").gov"
        echo userspace > "${q}/scaling_governor"
        tr ' ' '\n' < "${q}/scaling_available_frequencies" | grep -E '^[0-9]+$' | sort -n | head -n 1 > "${q}/scaling_setspeed"
    done
}

release_low() {
    local q
    for q in "${SYS_CPU}"/cpufreq/policy*; do
        [ -r "${OUTPUT}/$(basename "${q}").gov" ] || continue
        cat "${OUTPUT}/$(basename "${q}").gov" > "${q}/scaling_governor"
        rm "${OUTPUT}/$(basename "${q}").gov"
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
    local old_min
    local old_max
    local r
    local all
    local i
    local spin
    name="$(basename "${p}")"
    if [ -z "$(cat "${p}/affected_cpus")" ]; then
        info_msg "${name}: no online CPU"
        report_skip "${name}-min"
        report_skip "${name}-max"
        report_skip "${name}-runtime-ratio"
        return
    fi
    if ! grep -qw userspace "${p}/scaling_available_governors" ||
       [ ! -r "${p}/scaling_available_frequencies" ]; then
        info_msg "${name}: no userspace governor or frequency table"
        report_skip "${name}-min"
        report_skip "${name}-max"
        report_skip "${name}-runtime-ratio"
        return
    fi
    freqs="$(tr ' ' '\n' < "${p}/scaling_available_frequencies" | grep -E '^[0-9]+$' | sort -n)"
    lo="$(echo "${freqs}" | head -n 1)"
    hi="$(echo "${freqs}" | tail -n 1)"
    old="$(cat "${p}/scaling_governor")"
    old_min="$(cat "${p}/scaling_min_freq")"
    old_max="$(cat "${p}/scaling_max_freq")"
    echo "${hi}" > "${p}/scaling_max_freq"
    echo "${lo}" > "${p}/scaling_min_freq"
    echo userspace > "${p}/scaling_governor"
    # EPSS reports the domain state, not the vote, while every CPU of the
    # domain idles (SM8650 reads 460800 or 1382400 kHz whatever the vote,
    # on stock firmware too): read back with a loop on the first CPU.
    spin=""
    if [ -n "${PIN}" ]; then
        pinned "$(cut -d ' ' -f 1 "${p}/affected_cpus")" 'while :; do :; done' > /dev/null 2>&1 &
        spin=$!
    fi
    for t in min:"${lo}" max:"${hi}"; do
        [ "${t%%:*}" = max ] || hold_low "${p}"
        echo "${t#*:}" > "${p}/scaling_setspeed"
        sleep "${SETTLE_SECONDS}"
        if [ -n "${spin}" ] && ! kill -0 "${spin}" 2> /dev/null; then
            spin=""
        fi
        [ -n "${spin}" ] || info_msg "${name}: no loop keeps the domain busy, reading it idle"
        # One readback cannot tell a steady frequency from a passing one:
        # report the first of SAMPLES that differs, or the request.
        all=""
        r=""
        i=0
        while [ "${i}" -lt "${SAMPLES}" ]; do
            [ "${i}" -eq 0 ] || sleep 0.2
            all="${all} $(cur_freq "${p}")"
            i=$((i + 1))
        done
        for i in ${all}; do
            [ -n "${r}" ] || [ "${i}" = "${t#*:}" ] || r="${i}"
        done
        [ -n "${r}" ] || r="${t#*:}"
        [ "${t%%:*}" = max ] || release_low
        info_msg "${name}: set ${t#*:} read${all}${spin:+ (domain busy)}"
        if ! real_freq "${p}" "${r}"; then
            report_skip "${name}-${t%%:*}"
        elif [ "${r}" = "${t#*:}" ]; then
            add_metric "${name}-${t%%:*}" "pass" "${r}" "kHz"
        else
            add_metric "${name}-${t%%:*}" "fail" "${r}" "kHz"
        fi
    done
    if [ -n "${spin}" ]; then
        kill "${spin}"
        wait "${spin}"
    fi
    timed "${p}" "${lo}" "${hi}"
    echo "${old}" > "${p}/scaling_governor"
    echo "${old_min}" > "${p}/scaling_min_freq"
    echo "${old_max}" > "${p}/scaling_max_freq"
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
pin_setup
for p in "${SYS_CPU}"/cpufreq/policy*; do
    drive "${p}"
done
pin_cleanup

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
    if ! real_freq "${p}" "${peak}"; then
        report_skip "${n}-scales-under-load"
    elif [ "${peak}" -gt "${lo}" ]; then
        add_metric "${n}-scales-under-load" "pass" "${peak}" "kHz"
    else
        add_metric "${n}-scales-under-load" "fail" "${peak}" "kHz"
    fi
done
show
exit 0
