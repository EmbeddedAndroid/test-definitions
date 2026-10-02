#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Qualcomm Technologies, Inc. and/or its subsidiaries.
#
# remoteproc restart test
#
# Stop and start each remoteproc through sysfs, ITERATIONS times: the state
# must read offline after the stop and running after the start, the rpmsg
# devices the remoteproc had before the first stop must come back bound to
# the same drivers, and the kernel must log no remoteproc crash, warning or
# oops meanwhile. Every step is a test case per remoteproc and iteration.
#
# REMOTEPROCS names the remoteprocs to restart; empty restarts every one
# present except those in SKIP. EXPECTED_FAIL lists remoteprocs known not to
# survive a restart, as <name>=<reason> separated by ';': they are reported
# as skip with the reason and not restarted, since a failed restart can take
# the kernel down with it. A name in either list with no remoteproc fails
# its "present" case.

# shellcheck disable=SC1091
. ../../lib/sh-test-lib
OUTPUT="$(pwd)/output"
RESULT_FILE="${OUTPUT}/result.txt"
export RESULT_FILE
SYSFS_REMOTEPROC="/sys/class/remoteproc"
SYSFS_RPMSG="/sys/bus/rpmsg/devices"
REMOTEPROCS=""
SKIP="modem wpss"
EXPECTED_FAIL=""
ITERATIONS="3"
WAIT_SECONDS="30"
SETTLE_SECONDS="5"
STEPS="stop offline start running channels kernel-clean"
ISSUES="crash detected|fatal error received|watchdog received|WARNING:|BUG:|Oops|Internal error|Unable to handle|Call trace:|Kernel panic|external abort|blocked for more than"

usage() {
    echo "Usage: $0 [-d '<remoteproc> ...'] [-s '<remoteproc> ...']" 1>&2
    echo "          [-x '<remoteproc>=<reason>;...'] [-n <iterations>]" 1>&2
    echo "          [-w <wait s>] [-t <settle s>]" 1>&2
    exit 1
}

while getopts "d:s:x:n:w:t:h" o; do
    case "$o" in
        d) REMOTEPROCS="${OPTARG}" ;;
        s) SKIP="${OPTARG}" ;;
        x) EXPECTED_FAIL="${OPTARG}" ;;
        n) ITERATIONS="${OPTARG}" ;;
        w) WAIT_SECONDS="${OPTARG}" ;;
        t) SETTLE_SECONDS="${OPTARG}" ;;
        h|*) usage ;;
    esac
done

list_remoteprocs() {
    for dir in "${SYSFS_REMOTEPROC}"/remoteproc*; do
        [ -r "${dir}/name" ] && echo "${dir}"
    done
}

remoteprocs_by_name() {
    for dir in $(list_remoteprocs); do
        [ "$(cat "${dir}/name")" = "$1" ] && echo "${dir}"
    done
    return 0
}

# The remoteprocN index follows probe order, so a name shared by several
# remoteprocs is told apart by its platform device, as remoteproc-smoke does.
case_id() {
    local name
    name="$(cat "$1/name")"
    if [ "$(remoteprocs_by_name "${name}" | wc -l)" -gt 1 ]; then
        echo "${name}-$(basename "$(readlink -f "$1/device")")"
    else
        echo "${name}"
    fi
}

in_list() {
    for x in $2; do
        [ "$1" = "${x}" ] && return 0
    done
    return 1
}

expected_fail_names() {
    echo "${EXPECTED_FAIL}" | tr ';' '\n' | sed -n 's/^ *\([^=]*[^= ]\) *=.*/\1/p'
}

expected_fail_reason() {
    echo "${EXPECTED_FAIL}" | tr ';' '\n' |
        awk -F= -v n="$1" '{ k = $1; gsub(/ /, "", k) } k == n { sub(/^[^=]*= */, ""); print; exit }'
}

# result <case> <pass|fail> [<measurement> <unit>]
result() {
    if [ "$#" -ge 4 ]; then
        add_metric "$1" "$2" "$3" "$4"
    elif [ "$2" = pass ]; then
        report_pass "$1"
    else
        report_fail "$1"
    fi
}

state() {
    cat "${DIR}/state" 2>/dev/null
}

# write_state <stop|start>: exit status of the sysfs write, 124 when it has
# not returned after WAIT_SECONDS (a remoteproc stuck in its stop or start
# path must not hang the test).
write_state() {
    local pid
    local i=0
    (echo "$1" > "${DIR}/state") 2> "${OUTPUT}/write.err" &
    pid=$!
    while kill -0 "${pid}" 2>/dev/null; do
        if [ "${i}" -ge "${WAIT_SECONDS}" ]; then
            kill "${pid}" 2>/dev/null
            return 124
        fi
        sleep 1
        i=$((i + 1))
    done
    wait "${pid}"
}

# wait_state <state>: seconds until the remoteproc reads <state>, or fail
wait_state() {
    local i=0
    while [ "$(state)" != "$1" ]; do
        [ "${i}" -ge "${WAIT_SECONDS}" ] && return 1
        sleep 1
        i=$((i + 1))
    done
    echo "${i}"
}

# channels: "<rpmsg device> <driver or ->" for every rpmsg device below the
# remoteproc's device (its glink or smd edge)
channels() {
    local dev
    local drv
    dev="$(readlink -f "${DIR}/device")"
    for r in "${SYSFS_RPMSG}"/*; do
        [ -e "${r}" ] || continue
        case "$(readlink -f "${r}")" in
            "${dev}"/*) ;;
            *) continue ;;
        esac
        drv="-"
        [ -e "${r}/driver" ] && drv="$(basename "$(readlink -f "${r}/driver")")"
        echo "$(basename "${r}") ${drv}"
    done | sort
}

# missing_channels <list>: lines of <list> not in the current channels
missing_channels() {
    local now
    now="$(channels)"
    echo "$1" | while read -r line; do
        [ -n "${line}" ] || continue
        echo "${now}" | grep -qxF "${line}" || echo "${line}"
    done
}

# mark: put a unique line in the kernel log to find this step's messages
mark() {
    MARK="remoteproc-restart: ${CASE} iteration $1 at $(cut -d' ' -f1 /proc/uptime)"
    T0="$(cut -d' ' -f1 /proc/uptime)"
    echo "<6>${MARK}" 2>/dev/null > /dev/kmsg || MARK=""
}

# since_mark: kernel log lines after the last mark (or, without /dev/kmsg,
# after its uptime)
since_mark() {
    if [ -n "${MARK}" ] && dmesg | grep -qF "${MARK}"; then
        dmesg | awk -v m="${MARK}" 'f { print } index($0, m) { f = 1 }'
    else
        dmesg | awk -v t="${T0}" '{ s = $0; sub(/^\[ */, "", s); if (s + 0 > t) print }'
    fi
}

skip_from() { # <iteration> <first step to skip>
    local i="$1"
    local skipping=""
    while [ "${i}" -le "${ITERATIONS}" ]; do
        for s in ${STEPS}; do
            [ "${s}" = "$2" ] && skipping=1
            [ -n "${skipping}" ] && report_skip "${CASE}-${s}-${i}"
        done
        skipping=1
        i=$((i + 1))
    done
}

# restart_iteration <i>: one stop and start; returns 1 after a failed step
# once the following steps cannot run, 0 otherwise. The rpmsg devices must
# come back as they were before the first stop (BEFORE).
restart_iteration() {
    local i="$1"
    local rc
    local t
    local s0
    local lost
    local n

    mark "${i}"
    s0="$(state)"
    if [ "${s0}" = running ] || [ "${s0}" = attached ]; then
        write_state stop
        rc=$?
        if [ "${rc}" -eq 0 ]; then
            result "${CASE}-stop-${i}" pass
        else
            info_msg "${CASE}: stop returned ${rc}: $(cat "${OUTPUT}/write.err" 2>/dev/null)"
            result "${CASE}-stop-${i}" fail
        fi
    else
        info_msg "${CASE}: ${s0:-no state} before the stop, not running"
        result "${CASE}-stop-${i}" fail
    fi
    if t="$(wait_state offline)"; then
        result "${CASE}-offline-${i}" pass "${t}" s
    else
        info_msg "${CASE}: $(state) ${WAIT_SECONDS} s after the stop"
        result "${CASE}-offline-${i}" fail
        since_mark | head -n 40
        skip_from "${i}" start
        return 1
    fi
    if [ -n "$(channels)" ]; then
        info_msg "${CASE}: rpmsg devices left after the stop:"
        channels
    fi

    t="$(date +%s)"
    write_state start
    rc=$?
    t=$(($(date +%s) - t))
    if [ "${rc}" -eq 0 ]; then
        result "${CASE}-start-${i}" pass "${t}" s
    else
        info_msg "${CASE}: start returned ${rc}: $(cat "${OUTPUT}/write.err" 2>/dev/null)"
        result "${CASE}-start-${i}" fail
    fi
    if t="$(wait_state running)"; then
        result "${CASE}-running-${i}" pass "${t}" s
    else
        info_msg "${CASE}: $(state) ${WAIT_SECONDS} s after the start"
        result "${CASE}-running-${i}" fail
        since_mark | head -n 40
        skip_from "${i}" channels
        return 1
    fi

    n="$(echo "${BEFORE}" | grep -c .)"
    if [ "${n}" -eq 0 ]; then
        info_msg "${CASE}: no rpmsg devices before the first stop"
        report_skip "${CASE}-channels-${i}"
    else
        t=0
        lost="$(missing_channels "${BEFORE}")"
        while [ -n "${lost}" ] && [ "${t}" -lt "${WAIT_SECONDS}" ]; do
            sleep 1
            t=$((t + 1))
            lost="$(missing_channels "${BEFORE}")"
        done
        if [ -z "${lost}" ]; then
            result "${CASE}-channels-${i}" pass "${n}" channels
        else
            info_msg "${CASE}: not back (rpmsg device, driver) after ${t} s:"
            echo "${lost}"
            info_msg "${CASE}: now:"
            channels
            result "${CASE}-channels-${i}" fail
        fi
    fi

    sleep "${SETTLE_SECONDS}"
    info_msg "${CASE}: kernel log since the stop:"
    since_mark | head -n 40
    n="$(since_mark | grep -cE "${ISSUES}")"
    if [ "${n}" -eq 0 ] && [ "$(state)" = running ]; then
        result "${CASE}-kernel-clean-${i}" pass 0 lines
    else
        info_msg "${CASE}: $(state) ${SETTLE_SECONDS} s after the start, ${n} lines:"
        since_mark | grep -E "${ISSUES}" | head -n 20
        result "${CASE}-kernel-clean-${i}" fail "${n}" lines
    fi
    return 0
}

restart_remoteproc() {
    local i=1
    DIR="$1"
    CASE="$(case_id "${DIR}")"
    S_START="$(state)"
    BEFORE="$(channels)"
    info_msg "${CASE}: $(basename "${DIR}"), ${S_START}, ${ITERATIONS} restarts"
    if [ -n "${BEFORE}" ]; then
        info_msg "${CASE}: rpmsg devices (device, driver):"
        echo "${BEFORE}"
    fi
    while [ "${i}" -le "${ITERATIONS}" ]; do
        if ! restart_iteration "${i}"; then
            break
        fi
        i=$((i + 1))
    done
    # Leave a remoteproc that was running before the test running, for the
    # tests after this one.
    if { [ "${S_START}" = running ] || [ "${S_START}" = attached ]; } && [ "$(state)" = offline ]; then
        write_state start
        wait_state running > /dev/null
    fi
    info_msg "${CASE}: $(state) at the end"
}

create_out_dir "${OUTPUT}"
info_msg "remoteprocs present (name, state, firmware):"
for dir in $(list_remoteprocs); do
    fw="$(cat "${dir}/firmware" 2>/dev/null)"
    note=""
    [ -n "${fw}" ] && [ ! -e "/lib/firmware/${fw}" ] && note=" (not in /lib/firmware)"
    echo "$(basename "${dir}") $(cat "${dir}/name") $(cat "${dir}/state") ${fw}${note}"
done

# Listed remoteprocs are probed asynchronously; give them WAIT_SECONDS to
# register.
# shellcheck disable=SC2086
listed="$({ printf '%s\n' ${REMOTEPROCS}; expected_fail_names; } | awk 'NF && !s[$0]++')"
i=0
while [ "${i}" -lt "${WAIT_SECONDS}" ]; do
    absent=""
    for name in ${listed}; do
        [ -z "$(remoteprocs_by_name "${name}")" ] && absent="${absent} ${name}"
    done
    [ -z "${absent}" ] && break
    sleep 1
    i=$((i + 1))
done

dirs=""
if [ -n "${REMOTEPROCS}" ]; then
    names="${listed}"
else
    names="$(for dir in $(list_remoteprocs); do cat "${dir}/name"; done | awk '!s[$0]++')"
    for name in $(expected_fail_names); do
        if [ -z "$(remoteprocs_by_name "${name}")" ]; then
            info_msg "${name} is in EXPECTED_FAIL, but no remoteproc has that name"
            report_fail "${name}-present"
        fi
    done
fi
if [ -z "${names}" ]; then
    info_msg "no remoteproc to restart"
    report_skip "remoteproc-device-exists"
    exit 0
fi
for name in ${names}; do
    found="$(remoteprocs_by_name "${name}")"
    if [ -n "${REMOTEPROCS}" ]; then
        if [ -z "${found}" ]; then
            info_msg "no remoteproc named ${name}; present: $(for d in $(list_remoteprocs); do cat "${d}/name"; done | tr '\n' ' ')"
            report_fail "${name}-present"
            continue
        fi
        report_pass "${name}-present"
    fi
    if in_list "${name}" "${SKIP}"; then
        info_msg "${name} is in SKIP, not restarted"
        report_skip "${name}"
        continue
    fi
    reason="$(expected_fail_reason "${name}")"
    if [ -n "${reason}" ]; then
        info_msg "${name} is expected to fail (${reason}), not restarted"
        report_skip "${name}"
        continue
    fi
    dirs="${dirs} ${found}"
done

for dir in ${dirs}; do
    restart_remoteproc "${dir}"
done
exit 0
