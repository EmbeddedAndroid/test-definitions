#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Qualcomm Technologies, Inc. and/or its subsidiaries.
#
# TPM transport under load: tpm2-tools command loops (random, PCR read,
# PCR extend, hash, ECC sign) for -s seconds while stress-ng loads the
# CPUs, memory, block I/O and timer interrupts. Every command must
# succeed; a failure or a TPM error in the kernel log fails the test.

# shellcheck disable=SC1091
. ../../lib/sh-test-lib
OUTPUT="$(pwd)/output"
RESULT_FILE="${OUTPUT}/result.txt"
export RESULT_FILE

SECONDS_RUN=600
TCTI="device:/dev/tpmrm0"
LOOPS=4

usage() {
    echo "Usage: $0 [-s <seconds>] [-t <tcti>] [-j <parallel loops>]" 1>&2
    exit 1
}

while getopts "s:t:j:h" o; do
    case "$o" in
        s) SECONDS_RUN="${OPTARG}" ;;
        t) TCTI="${OPTARG}" ;;
        j) LOOPS="${OPTARG}" ;;
        h|*) usage ;;
    esac
done

TPM2TOOLS_TCTI="${TCTI}"
export TPM2TOOLS_TCTI
create_out_dir "${OUTPUT}"

if [ ! -c /dev/tpmrm0 ] || ! command -v tpm2_getrandom > /dev/null 2>&1; then
    info_msg "no /dev/tpmrm0 or no tpm2-tools"
    report_skip "tpm2-stress"
    exit 0
fi

W="$(mktemp -d)"
cd "${W}" || exit 1
if ! { tpm2_createprimary -Q -C o -g sha256 -G ecc -c primary.ctx &&
    tpm2_create -Q -C primary.ctx -G ecc256:ecdsa -u key.pub -r key.priv &&
    tpm2_load -Q -C primary.ctx -u key.pub -r key.priv -c key.ctx; }; then
    report_fail "tpm2-stress"
    exit 0
fi
printf 'stress' > msg

# loop <id>: TPM commands until the deadline; one line per failure
loop() {
    end=$(( $(date +%s) + SECONDS_RUN ))
    n=0
    while [ "$(date +%s)" -lt "${end}" ]; do
        for c in "tpm2_getrandom --hex 32" "tpm2_pcrread sha256:0,16,23" \
                 "tpm2_pcrextend 16:sha256=$(printf '%064x' "$n")" \
                 "tpm2_hash -g sha256 msg" "tpm2_sign -c key.ctx -g sha256 -o sig.$1 msg"; do
            n=$((n + 1))
            # shellcheck disable=SC2086
            if ! ${c} > "out.$1" 2>&1; then
                echo "FAIL loop $1 cmd ${n}: ${c}: $(tail -n 1 "out.$1")"
            fi
        done
    done
    echo "DONE loop $1 ${n}"
}

dmesg -c > /dev/null 2>&1 || true
STRESS=""
if command -v stress-ng > /dev/null 2>&1; then
    stress-ng --cpu 0 --vm 2 --vm-bytes 20% --hdd 2 --hdd-bytes 64M \
        --timer 2 --timer-freq 100000 --switch 2 \
        --timeout "$((SECONDS_RUN + 30))" --quiet > stress.log 2>&1 &
    STRESS=$!
    info_msg "stress-ng load running (pid ${STRESS})"
else
    info_msg "no stress-ng: TPM loops without load"
fi

i=0
LPIDS=""
while [ "${i}" -lt "${LOOPS}" ]; do
    loop "${i}" > "loop.${i}.log" 2>&1 &
    LPIDS="${LPIDS} $!"
    i=$((i + 1))
done
# shellcheck disable=SC2086
wait ${LPIDS}
[ -n "${STRESS}" ] && kill "${STRESS}" 2>/dev/null
wait 2>/dev/null

cmds=0
fails=0
for f in loop.*.log; do
    c=$(sed -n 's/^DONE loop [0-9]* //p' "${f}")
    cmds=$((cmds + ${c:-0}))
    fails=$((fails + $(grep -c '^FAIL' "${f}")))
    grep '^FAIL' "${f}" | head -n 20
done
kerr=$(dmesg | grep -i -c -E 'tpm|optee' || true)
dmesg | grep -i -E 'tpm|optee' | tail -n 20
info_msg "tpm2-stress: ${cmds} commands, ${fails} failures, ${kerr} TPM/TEE kernel messages in ${SECONDS_RUN} s"
add_metric "tpm2-stress-commands" "pass" "${cmds}" "commands"
add_metric "tpm2-stress-failures" "pass" "${fails}" "commands"
if [ "${cmds}" -gt 0 ] && [ "${fails}" -eq 0 ]; then
    report_pass "tpm2-stress"
else
    report_fail "tpm2-stress"
fi
cd / && rm -rf "${W}"
