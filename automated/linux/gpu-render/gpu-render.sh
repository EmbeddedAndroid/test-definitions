#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Qualcomm Technologies, Inc. and/or its subsidiaries.
#
# Headless GPU check: a DRM render node bound to the expected driver, then a
# render test that draws on the GPU and reads the pixels back (by default
# egl-readback, which renders through GBM and EGL and fails on a software
# renderer). Without a render node the test is skipped; without the render
# test command (no Mesa in the image) only the render case is skipped.

# shellcheck disable=SC1091
. ../../lib/sh-test-lib
OUTPUT="$(pwd)/output"
RESULT_FILE="${OUTPUT}/result.txt"
export RESULT_FILE

DRIVER=""
TEST_CMD="egl-readback"

usage() {
    echo "Usage: $0 [-d <drm driver>] [-c <render test command>]" 1>&2
    exit 1
}

while getopts "d:c:h" o; do
    case "$o" in
        d) DRIVER="${OPTARG}" ;;
        c) TEST_CMD="${OPTARG}" ;;
        h|*) usage ;;
    esac
done

create_out_dir "${OUTPUT}"

node=""
for r in /sys/class/drm/renderD*; do
    [ -e "${r}/device/driver" ] || continue
    drv="$(basename "$(readlink "${r}/device/driver")")"
    info_msg "$(basename "${r}"): ${drv}"
    if [ -z "${DRIVER}" ] || [ "${drv}" = "${DRIVER}" ]; then
        node="/dev/dri/$(basename "${r}")"
        break
    fi
done
if [ -z "${node}" ]; then
    info_msg "no render node${DRIVER:+ for ${DRIVER}}"
    report_skip "gpu-render-node"
    report_skip "gpu-render"
    exit 0
fi
info_msg "render node ${node}"
report_pass "gpu-render-node"

cmd="${TEST_CMD%% *}"
if ! command -v "${cmd}" > /dev/null; then
    warn_msg "${cmd} is not installed: the image has no GPU userspace test"
    report_skip "gpu-render"
    exit 0
fi
# shellcheck disable=SC2086
${TEST_CMD} > "${OUTPUT}/gpu-render.log" 2>&1
rc=$?
cat "${OUTPUT}/gpu-render.log"
if [ "${rc}" -eq 0 ]; then
    report_pass "gpu-render"
else
    info_msg "${TEST_CMD} exited ${rc}"
    report_fail "gpu-render"
fi
dmesg | grep -iE "gpu fault|hangcheck|gmu.*timeout|zap" | tail -n 10
exit 0
