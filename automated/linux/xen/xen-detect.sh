#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Qualcomm Technologies, Inc. and/or its subsidiaries.
#
# Is Linux the Xen control domain (dom0), and which Xen: the hypervisor
# type and version in /sys/hypervisor, control_d in /proc/xen/capabilities,
# the guest ABI capabilities, and optionally a version pattern and a build
# fingerprint in the Xen boot banner. Without Xen every case is skipped,
# so the plan's Xen block runs on every boot of a board; REQUIRE_XEN=true
# fails them instead.

# shellcheck disable=SC1091
. ../../lib/sh-test-lib
# shellcheck disable=SC1091
. ./xen-lib.sh
OUTPUT="$(pwd)/output"
RESULT_FILE="${OUTPUT}/result.txt"
export RESULT_FILE

REQUIRE_XEN="false"
VERSION=""
CAPS=""
FINGERPRINT=""

usage() {
    echo "Usage: $0 [-r <true|false>] [-v <version regex>] [-c <capability>]" 1>&2
    echo "          [-f <fingerprint>]" 1>&2
    exit 1
}

while getopts "r:v:c:f:h" o; do
    case "$o" in
        r) REQUIRE_XEN="${OPTARG}" ;;
        v) VERSION="${OPTARG}" ;;
        c) CAPS="${OPTARG}" ;;
        f) FINGERPRINT="${OPTARG}" ;;
        h|*) usage ;;
    esac
done

create_out_dir "${OUTPUT}"

CASES="xen-hypervisor xen-dom0 xen-version xen-capabilities xen-fingerprint"
# shellcheck disable=SC2086
xen_require "${REQUIRE_XEN}" ${CASES}
report_pass "xen-hypervisor"
report_pass "xen-dom0"

v="$(cat "${XEN_SYS}/version/major" 2> /dev/null).$(cat "${XEN_SYS}/version/minor" 2> /dev/null)$(cat "${XEN_SYS}/version/extra" 2> /dev/null)"
info_msg "Xen ${v}"
if ! echo "${v}" | grep -q -E '^[0-9]+\.[0-9]+'; then
    report_fail "xen-version"
elif [ -n "${VERSION}" ]; then
    echo "${v}" | grep -q -E "${VERSION}"
    check_return "xen-version"
else
    report_pass "xen-version"
fi

caps="$(cat "${XEN_SYS}/properties/capabilities" 2> /dev/null)"
info_msg "capabilities: ${caps}"
if [ -z "${caps}" ]; then
    report_fail "xen-capabilities"
elif [ -n "${CAPS}" ]; then
    echo " ${caps} " | grep -q -F " ${CAPS} "
    check_return "xen-capabilities"
else
    report_pass "xen-capabilities"
fi

# /sys/hypervisor/version/extra is cut short; the banner in the Xen
# console ring has the whole version string.
if [ -z "${FINGERPRINT}" ]; then
    report_skip "xen-fingerprint"
elif ! command -v xl > /dev/null; then
    warn_msg "no xl to read the Xen console ring"
    report_skip "xen-fingerprint"
else
    xl dmesg > "${OUTPUT}/xl-dmesg.txt" 2>&1
    grep -m 1 'Xen version' "${OUTPUT}/xl-dmesg.txt"
    grep 'Xen version' "${OUTPUT}/xl-dmesg.txt" | grep -q -F "${FINGERPRINT}"
    check_return "xen-fingerprint"
fi
exit 0
