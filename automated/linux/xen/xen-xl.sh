#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Qualcomm Technologies, Inc. and/or its subsidiaries.
#
# The Xen toolstack in dom0 and guests: xenstored, xen-init-dom0 and
# xenconsoled start, xl info, list and dmesg answer; a 1-vCPU guest boots
# and shuts down on "xl shutdown"; N guests boot in parallel, each is seen
# running and each shuts down cleanly; a destroyed guest is gone and its
# memory is back. Guest states are read from each guest's console (the
# protocol of README.md), never from timing. Skipped without Xen; the
# guest cases are skipped without the guest image.

# shellcheck disable=SC1091
. ../../lib/sh-test-lib
# shellcheck disable=SC1091
. ./xen-lib.sh
OUTPUT="$(pwd)/output"
RESULT_FILE="${OUTPUT}/result.txt"
export RESULT_FILE
XEN_LOGDIR="${OUTPUT}/console"

KERNEL="/opt/xen-guest/Image"
INITRD="/opt/xen-guest/initramfs.cpio.gz"
MEMORY="256"
VCPUS="2"
PARALLEL="4"
TIMEOUT="120"

usage() {
    echo "Usage: $0 [-k <guest kernel>] [-i <guest initramfs>] [-m <memory MiB>]" 1>&2
    echo "          [-c <vcpus>] [-n <parallel guests>] [-t <timeout s>]" 1>&2
    exit 1
}

while getopts "k:i:m:c:n:t:h" o; do
    case "$o" in
        k) KERNEL="${OPTARG}" ;;
        i) INITRD="${OPTARG}" ;;
        m) MEMORY="${OPTARG}" ;;
        c) VCPUS="${OPTARG}" ;;
        n) PARALLEL="${OPTARG}" ;;
        t) TIMEOUT="${OPTARG}" ;;
        h|*) usage ;;
    esac
done

create_out_dir "${OUTPUT}"

TOOL_CASES="xl-present xenstored xen-init-dom0 xenconsoled xl-info xl-list-dom0 xl-dmesg"
GUEST_CASES="guest-1vcpu-boot guest-1vcpu-vcpus guest-1vcpu-shutdown"
GUEST_CASES="${GUEST_CASES} parallel-${PARALLEL}-boot parallel-${PARALLEL}-running parallel-${PARALLEL}-shutdown"
GUEST_CASES="${GUEST_CASES} destroy destroy-memory-returned"
# shellcheck disable=SC2086
xen_require "false" ${TOOL_CASES} ${GUEST_CASES}

if ! command -v xl > /dev/null; then
    report_fail "xl-present"
    # shellcheck disable=SC2086
    xen_skip_cases "no xl: the image has no Xen toolstack" xenstored xen-init-dom0 xenconsoled \
        xl-info xl-list-dom0 xl-dmesg ${GUEST_CASES}
fi
report_pass "xl-present"

if xen_toolstack "${XEN_LOGDIR}"; then
    report_pass "xenstored"
    report_pass "xen-init-dom0"
    report_pass "xenconsoled"
else
    cat "${XEN_LOGDIR}"/*.log 2> /dev/null
    reached=1
    for c in xenstored xen-init-dom0 xenconsoled; do
        if [ "${c}" = "${XEN_TOOLSTACK_ERROR}" ]; then
            report_fail "${c}"
            reached=0
        elif [ "${reached}" -eq 1 ]; then
            report_pass "${c}"
        else
            report_skip "${c}"
        fi
    done
    # shellcheck disable=SC2086
    xen_skip_cases "the toolstack did not start (${XEN_TOOLSTACK_ERROR})" xl-info xl-list-dom0 xl-dmesg ${GUEST_CASES}
fi

xl info > "${OUTPUT}/xl-info.txt" 2>&1
check_return "xl-info"
cat "${OUTPUT}/xl-info.txt"
xl list > "${OUTPUT}/xl-list.txt" 2>&1 && grep -q '^Domain-0 ' "${OUTPUT}/xl-list.txt"
check_return "xl-list-dom0"
xl dmesg > "${OUTPUT}/xl-dmesg.txt" 2>&1 && grep -q 'Xen version' "${OUTPUT}/xl-dmesg.txt"
check_return "xl-dmesg"

# shellcheck disable=SC2086
guest_check_image "${KERNEL}" "${INITRD}" ${GUEST_CASES}

# create <name> <vcpus>: xl create of a guest that stays up until asked to
# shut down.
create() {
    xen_guest_cfg "${OUTPUT}/$1.cfg" "$1" "${KERNEL}" "${INITRD}" "${MEMORY}" "$2"
    xl create "${OUTPUT}/$1.cfg" > "${OUTPUT}/create-$1.log" 2>&1 || {
        cat "${OUTPUT}/create-$1.log"
        return 1
    }
}

# shutdown_clean <name>: xl shutdown, the guest's init reports the request
# and the domain is gone.
shutdown_clean() {
    xl shutdown "$1" > "${OUTPUT}/shutdown-$1.log" 2>&1 || cat "${OUTPUT}/shutdown-$1.log"
    if guest_gone "$1" "${TIMEOUT}"; then
        guest_log "$1" | grep -q "xen-guest: poweroff name=$1\$" && return 0
        warn_msg "$1 is gone without its poweroff line"
        return 1
    fi
    warn_msg "$1 still there ${TIMEOUT}s after xl shutdown"
    xl destroy "$1" 2> /dev/null
    return 1
}

show() {
    info_msg "console of $1:"
    guest_log "$1" | tail -n 20
}

# 1. One guest with one vCPU.
g=xt-up1
if create "${g}" 1 && guest_wait "${g}" "xen-guest: ready name=${g} " "${TIMEOUT}"; then
    report_pass "guest-1vcpu-boot"
    guest_log "${g}" | grep -q "xen-guest: ready name=${g} vcpus=1 "
    check_return "guest-1vcpu-vcpus"
    shutdown_clean "${g}"
    check_return "guest-1vcpu-shutdown"
else
    report_fail "guest-1vcpu-boot"
    report_skip "guest-1vcpu-vcpus"
    report_skip "guest-1vcpu-shutdown"
    xl destroy "${g}" 2> /dev/null
fi
show "${g}"

# 2. PARALLEL guests created back to back: each must reach its ready
# line, still be a running domain afterwards, and shut down cleanly.
names=""
n=1
while [ "${n}" -le "${PARALLEL}" ]; do
    names="${names} xt-par${n}"
    create "xt-par${n}" "${VCPUS}"
    n=$((n + 1))
done
up=0
for g in ${names}; do
    guest_wait "${g}" "xen-guest: ready name=${g} vcpus=${VCPUS} " "${TIMEOUT}" && up=$((up + 1))
done
xl list
[ "${up}" -eq "${PARALLEL}" ]
check_return "parallel-${PARALLEL}-boot"
alive=0
for g in ${names}; do
    xl list "${g}" 2> /dev/null | grep -q "^${g} " && alive=$((alive + 1))
done
[ "${alive}" -eq "${PARALLEL}" ]
check_return "parallel-${PARALLEL}-running"
for g in ${names}; do
    xl shutdown "${g}" > /dev/null 2>&1
done
clean=0
for g in ${names}; do
    if guest_gone "${g}" "${TIMEOUT}"; then
        guest_log "${g}" | grep -q "xen-guest: poweroff name=${g}\$" && clean=$((clean + 1))
    else
        xl destroy "${g}" 2> /dev/null
    fi
    show "${g}"
done
[ "${clean}" -eq "${PARALLEL}" ]
check_return "parallel-${PARALLEL}-shutdown"

# 3. xl destroy of a running guest; its memory comes back. The baseline
# is taken once the memory of the guests above has come back too.
g=xt-destroy
free0="$(xen_free_memory_settled 60)"
if create "${g}" "${VCPUS}" && guest_wait "${g}" "xen-guest: ready name=${g} " "${TIMEOUT}"; then
    xl destroy "${g}" && guest_gone "${g}" "${TIMEOUT}"
    check_return "destroy"
    i=0
    while [ "$(xen_free_memory)" -lt "${free0:-0}" ] && [ "${i}" -lt 60 ]; do
        sleep 1
        i=$((i + 1))
    done
    free1="$(xen_free_memory)"
    info_msg "free memory before ${free0} MiB, after destroy ${free1} MiB"
    [ -n "${free0}" ] && [ -n "${free1}" ] && [ "${free1}" -ge "${free0}" ]
    check_return "destroy-memory-returned"
else
    report_fail "destroy"
    report_skip "destroy-memory-returned"
    xl destroy "${g}" 2> /dev/null
fi
show "${g}"
xl list
exit 0
