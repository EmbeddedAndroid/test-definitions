#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Qualcomm Technologies, Inc. and/or its subsidiaries.
#
# OP-TEE through a Xen TEE mediator, -m optee (the OP-TEE SMC ABI
# mediator, CONFIG_OPTEE) or -m ffa (the FF-A mediator, CONFIG_FFA, with
# OP-TEE as an FF-A partition): Xen selected the mediator, dom0's OP-TEE
# driver bound over the matching transport with /dev/tee0, optionally
# xtest in dom0; a guest created with tee="<mediator>" reaches OP-TEE, a
# guest without it does not, and destroying the guest leaves no dying
# domain (with FF-A: no shared memory Xen failed to reclaim). Skipped
# without Xen, or when Xen uses no such mediator (REQUIRE=true fails).

# shellcheck disable=SC1091
. ../../lib/sh-test-lib
# shellcheck disable=SC1091
. ./xen-lib.sh
OUTPUT="$(pwd)/output"
RESULT_FILE="${OUTPUT}/result.txt"
export RESULT_FILE
XEN_LOGDIR="${OUTPUT}/console"

MODE=""
REQUIRE="false"
XTEST=""
KERNEL="/opt/xen-guest/Image"
INITRD="/opt/xen-guest/initramfs.cpio.gz"
MEMORY="256"
TIMEOUT="120"

usage() {
    echo "Usage: $0 -m <optee|ffa> [-r <true|false>] [-x \"<xtest arguments>\"]" 1>&2
    echo "          [-k <guest kernel>] [-i <guest initramfs>] [-s <memory MiB>] [-t <timeout s>]" 1>&2
    exit 1
}

while getopts "m:r:x:k:i:s:t:h" o; do
    case "$o" in
        m) MODE="${OPTARG}" ;;
        r) REQUIRE="${OPTARG}" ;;
        x) XTEST="${OPTARG}" ;;
        k) KERNEL="${OPTARG}" ;;
        i) INITRD="${OPTARG}" ;;
        s) MEMORY="${OPTARG}" ;;
        t) TIMEOUT="${OPTARG}" ;;
        h|*) usage ;;
    esac
done

case "${MODE}" in
    optee) MEDIATOR="OP-TEE" ;;
    ffa) MEDIATOR="FF-A" ;;
    *) usage ;;
esac

create_out_dir "${OUTPUT}"

CASES="xen-mediator"
[ "${MODE}" = "ffa" ] && CASES="${CASES} xen-spmc-version dom0-ffa-driver"
CASES="${CASES} dom0-optee-bound dom0-tee-devices dom0-xtest"
GUEST_CASES="guest-tee-reachable guest-tee-denied guest-teardown"
# shellcheck disable=SC2086
xen_require "false" ${CASES} ${GUEST_CASES}
# shellcheck disable=SC2086
command -v xl > /dev/null || xen_skip_cases "no xl: the image has no Xen toolstack" ${CASES} ${GUEST_CASES}

xl dmesg > "${OUTPUT}/xl-dmesg.txt" 2>&1
dmesg > "${OUTPUT}/dmesg.txt"
grep -i -E 'TEE mediator|FF-A|ffa|optee' "${OUTPUT}/xl-dmesg.txt" | head -20

# dom0's OP-TEE driver over FF-A: an arm_ffa device has a driver bound.
optee_over_ffa() {
    for d in /sys/bus/arm_ffa/devices/*/driver; do
        [ -e "${d}" ] && return 0
    done
    return 1
}

# dom0's OP-TEE driver bound over the transport of this mediator.
optee_transport_ok() {
    grep -q 'optee: initialized driver' "${OUTPUT}/dmesg.txt" || return 1
    if [ "${MODE}" = "ffa" ]; then
        optee_over_ffa
    else
        ! optee_over_ffa
    fi
}

# Without the mediator line (it may have left a wrapped console ring),
# dom0's driver bound over the matching transport shows that Xen
# forwards its calls.
mediator=0
if grep -q "Using TEE mediator for ${MEDIATOR}\$" "${OUTPUT}/xl-dmesg.txt"; then
    mediator=1
elif ! grep -q 'Xen version' "${OUTPUT}/xl-dmesg.txt" && optee_transport_ok; then
    info_msg "Xen console ring wrapped; dom0's OP-TEE driver bound over ${MEDIATOR}"
    mediator=1
fi
if [ "${mediator}" -eq 0 ]; then
    if [ "${REQUIRE}" = "true" ]; then
        warn_msg "Xen uses no ${MEDIATOR} TEE mediator, which this job requires"
        report_fail "xen-mediator"
        rest="$(echo "${CASES} ${GUEST_CASES}" | sed 's/^xen-mediator //')"
        # shellcheck disable=SC2086
        xen_skip_cases "no ${MEDIATOR} mediator" ${rest}
    fi
    # shellcheck disable=SC2086
    xen_skip_cases "Xen uses no ${MEDIATOR} TEE mediator" ${CASES} ${GUEST_CASES}
fi
report_pass "xen-mediator"

if [ "${MODE}" = "ffa" ]; then
    grep -q 'ARM FF-A Firmware version [0-9]' "${OUTPUT}/xl-dmesg.txt"
    check_return "xen-spmc-version"
    grep -E 'ARM FF-A' "${OUTPUT}/dmesg.txt"
    grep -q 'ARM FF-A: Firmware version' "${OUTPUT}/dmesg.txt"
    check_return "dom0-ffa-driver"
fi

grep -E 'optee:' "${OUTPUT}/dmesg.txt"
optee_transport_ok
check_return "dom0-optee-bound"
[ -c /dev/tee0 ] && [ -c /dev/teepriv0 ]
check_return "dom0-tee-devices"

if [ -z "${XTEST}" ]; then
    report_skip "dom0-xtest"
elif ! command -v xtest > /dev/null; then
    warn_msg "no xtest"
    report_skip "dom0-xtest"
else
    proc_running tee-supplicant || tee-supplicant -d
    # shellcheck disable=SC2086
    xtest ${XTEST} > "${OUTPUT}/xtest.log" 2>&1
    rc=$?
    tail -n 20 "${OUTPUT}/xtest.log"
    [ "${rc}" -eq 0 ]
    check_return "dom0-xtest"
fi

if ! xen_toolstack "${XEN_LOGDIR}"; then
    cat "${XEN_LOGDIR}"/*.log 2> /dev/null
    # shellcheck disable=SC2086
    xen_skip_cases "the toolstack did not start (${XEN_TOOLSTACK_ERROR})" ${GUEST_CASES}
fi
# shellcheck disable=SC2086
guest_check_image "${KERNEL}" "${INITRD}" ${GUEST_CASES}

# guest <name> <tee>: the guest's "xen-guest: tee" line, empty when the
# guest did not report.
guest() {
    xen_guest_cfg "${OUTPUT}/$1.cfg" "$1" "${KERNEL}" "${INITRD}" "${MEMORY}" 1 "$2"
    cat "${OUTPUT}/$1.cfg"
    if ! xl create "${OUTPUT}/$1.cfg" > "${OUTPUT}/create-$1.log" 2>&1; then
        cat "${OUTPUT}/create-$1.log"
        return
    fi
    guest_wait "$1" "xen-guest: tee name=$1 " "${TIMEOUT}"
    info_msg "console of $1:"
    guest_log "$1" | grep -i -E 'xen-guest|ffa|FF-A|optee|tee' | tail -n 20
}

ffa_want=0
[ "${MODE}" = "ffa" ] && ffa_want=1
reclaim0="$(grep -c 'ffa: Failed to reclaim' "${OUTPUT}/xl-dmesg.txt")"

g=xt-tee
guest "${g}" "${MODE}"
guest_log "${g}" | grep -q "xen-guest: tee name=${g} ffa=${ffa_want} optee=1 tee0=1"
check_return "guest-tee-reachable"
xl destroy "${g}" > /dev/null 2>&1
ok=0
guest_gone "${g}" "${TIMEOUT}" && ok=1
xl list
# Xen retries a reclaim the SPMC refuses for as long as the domain dies.
reclaim1="$(xl dmesg 2>&1 | grep -c 'ffa: Failed to reclaim')"
if [ "${reclaim1}" -gt "${reclaim0}" ]; then
    warn_msg "Xen failed to reclaim FF-A shared memory of ${g}"
    xl dmesg | grep 'ffa: Failed to reclaim' | tail -n 3
    ok=0
fi
[ "${ok}" -eq 1 ]
check_return "guest-teardown"

g=xt-notee
guest "${g}" ""
guest_log "${g}" | grep -q "xen-guest: tee name=${g} ffa=0 optee=0 tee0=0"
check_return "guest-tee-denied"
xl destroy "${g}" > /dev/null 2>&1
guest_gone "${g}" "${TIMEOUT}" || warn_msg "${g} still there after xl destroy"
exit 0
