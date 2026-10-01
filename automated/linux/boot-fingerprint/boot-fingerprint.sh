#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Qualcomm Technologies, Inc. and/or its subsidiaries.
#
# Check that the running kernel and rootfs carry the expected build
# fingerprint, so results are never attributed to a stale image. Firmware
# stages (TF-A, OP-TEE, U-Boot, ...) print their fingerprint on the console
# only; the job checks those with a console monitor. From Linux, the
# firmware fingerprint can be read only where the firmware publishes it, e.g.
# U-Boot's SMBIOS BIOS version in /sys/class/dmi/id/bios_version.

# shellcheck disable=SC1091
. ../../lib/sh-test-lib
OUTPUT="$(pwd)/output"
RESULT_FILE="${OUTPUT}/result.txt"
export RESULT_FILE

FINGERPRINT=""
LINUX_FINGERPRINT=""
ROOTFS_FINGERPRINT=""
ROOTFS_FILES="/etc/issue /etc/os-release"
FIRMWARE_FINGERPRINT=""

usage() {
    echo "Usage: $0 -f <fingerprint> [-l <linux fingerprint>] [-r <rootfs fingerprint>]" 1>&2
    echo "          [-R <rootfs files>] [-F <firmware fingerprint>]" 1>&2
    exit 1
}

while getopts "f:l:r:R:F:h" o; do
    case "$o" in
        f) FINGERPRINT="${OPTARG}" ;;
        l) LINUX_FINGERPRINT="${OPTARG}" ;;
        r) ROOTFS_FINGERPRINT="${OPTARG}" ;;
        R) ROOTFS_FILES="${OPTARG}" ;;
        F) FIRMWARE_FINGERPRINT="${OPTARG}" ;;
        h|*) usage ;;
    esac
done

LINUX_FINGERPRINT="${LINUX_FINGERPRINT:-${FINGERPRINT}}"
ROOTFS_FINGERPRINT="${ROOTFS_FINGERPRINT:-${LINUX_FINGERPRINT}}"
FIRMWARE_FINGERPRINT="${FIRMWARE_FINGERPRINT:-${FINGERPRINT}}"

create_out_dir "${OUTPUT}"

if [ -z "${LINUX_FINGERPRINT}" ]; then
    warn_msg "No fingerprint given, nothing to check"
    report_skip "fingerprint-linux"
    report_skip "fingerprint-rootfs"
    report_skip "fingerprint-firmware-dmi"
    exit 0
fi

info_msg "kernel: $(cat /proc/version)"
if grep -qF -- "${LINUX_FINGERPRINT}" /proc/version; then
    report_pass "fingerprint-linux"
else
    info_msg "${LINUX_FINGERPRINT} is not in /proc/version"
    report_fail "fingerprint-linux"
fi

found=""
checked=""
for f in ${ROOTFS_FILES}; do
    [ -r "${f}" ] || continue
    checked="${checked} ${f}"
    if grep -qF -- "${ROOTFS_FINGERPRINT}" "${f}"; then
        found="${f}"
        break
    fi
done
if [ -n "${found}" ]; then
    info_msg "rootfs: ${ROOTFS_FINGERPRINT} found in ${found}"
    report_pass "fingerprint-rootfs"
elif [ -z "${checked}" ]; then
    info_msg "none of ${ROOTFS_FILES} is readable"
    report_skip "fingerprint-rootfs"
else
    info_msg "${ROOTFS_FINGERPRINT} is not in${checked}"
    report_fail "fingerprint-rootfs"
fi

dmi=/sys/class/dmi/id/bios_version
if [ -r "${dmi}" ]; then
    info_msg "DMI BIOS version: $(cat "${dmi}")"
    if grep -qF -- "${FIRMWARE_FINGERPRINT}" "${dmi}"; then
        report_pass "fingerprint-firmware-dmi"
    else
        report_fail "fingerprint-firmware-dmi"
    fi
else
    info_msg "no DMI BIOS version; firmware fingerprints are checked on the console"
    report_skip "fingerprint-firmware-dmi"
fi
exit 0
