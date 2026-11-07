#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Qualcomm Technologies, Inc. and/or its subsidiaries.
#
# TPM 2.0 functional checks with tpm2-tools: device nodes, capabilities,
# self test, PCR read/extend, random, ECC sign/verify, NV, quote, and the
# negative cases that must fail. See tpm2.yaml for the parameters.

# shellcheck disable=SC1091
. ../../lib/sh-test-lib
OUTPUT="$(pwd)/output"
RESULT_FILE="${OUTPUT}/result.txt"
export RESULT_FILE

TCTI="device:/dev/tpmrm0"
PCR=16
NV_INDEX=0x1500016
MANUFACTURER=""
LOCALITY_DENIED=""
LOCALITY_FILE="/sys/kernel/debug/tpm0/locality"
PCR17_SHA256=""

usage() {
    echo "Usage: $0 [-t <tcti>] [-p <pcr>] [-n <nv index>] [-m <manufacturer>]" 1>&2
    echo "          [-L <denied locality>] [-f <locality file>] [-d <pcr17 sha256>]" 1>&2
    exit 1
}

while getopts "t:p:n:m:L:f:d:h" o; do
    case "$o" in
        t) TCTI="${OPTARG}" ;;
        p) PCR="${OPTARG}" ;;
        n) NV_INDEX="${OPTARG}" ;;
        m) MANUFACTURER="${OPTARG}" ;;
        L) LOCALITY_DENIED="${OPTARG}" ;;
        f) LOCALITY_FILE="${OPTARG}" ;;
        d) PCR17_SHA256="${OPTARG}" ;;
        h|*) usage ;;
    esac
done

TPM2TOOLS_TCTI="${TCTI}"
export TPM2TOOLS_TCTI

CASES="dev-tpm0 dev-tpmrm0 tpm-version getcap selftest pcrread pcr-extend
getrandom key-sign-verify nv-define-write-read quote
negative-verify-tampered negative-quote-nonce negative-nvread-undefined
negative-pcr17-reset locality-denied locality-0-after-denied pcr17-locality4"

create_out_dir "${OUTPUT}"
W="$(mktemp -d)"

skip_all() {
    for c in ${CASES}; do
        report_skip "${c}"
    done
}

# check <case> <command...>: pass if the command succeeds
check() {
    c="$1"
    shift
    if "$@" > "${W}/${c}.log" 2>&1; then
        report_pass "${c}"
    else
        cat "${W}/${c}.log"
        report_fail "${c}"
    fi
}

# check_fails <case> <command...>: pass if the command fails
check_fails() {
    c="$1"
    shift
    if "$@" > "${W}/${c}.log" 2>&1; then
        info_msg "${c}: command succeeded but must fail"
        cat "${W}/${c}.log"
        report_fail "${c}"
    else
        info_msg "${c}: refused as expected: $(tail -n 2 "${W}/${c}.log" | tr '\n' ' ')"
        report_pass "${c}"
    fi
}

# hex2bin: hex string on stdin to bytes on stdout (no xxd in BusyBox)
hex2bin() {
    sed 's/../& /g' | tr ' ' '\n' | while read -r b; do
        # shellcheck disable=SC2059
        [ -n "${b}" ] && printf "\\$(printf '%03o' "0x${b}")"
    done
}

pcr_value() {
    tpm2_pcrread "sha256:$1" | sed -n 's/^ *[0-9]* *: *0x\([0-9A-Fa-f]*\).*/\1/p' |
        tr 'A-F' 'a-f'
}

if [ -c /dev/tpm0 ]; then
    report_pass "dev-tpm0"
else
    info_msg "no /dev/tpm0: $(ls /sys/class/tpm 2>&1)"
    skip_all
    exit 0
fi
if [ -c /dev/tpmrm0 ]; then
    report_pass "dev-tpmrm0"
else
    report_fail "dev-tpmrm0"
fi

if ! command -v tpm2_getcap > /dev/null 2>&1; then
    info_msg "tpm2-tools not installed"
    for c in ${CASES}; do
        case "${c}" in dev-*) ;; *) report_skip "${c}" ;; esac
    done
    exit 0
fi

v="$(cat /sys/class/tpm/tpm0/tpm_version_major 2>/dev/null)"
info_msg "tpm_version_major: ${v:-unknown}"
if [ "${v}" = 2 ]; then
    report_pass "tpm-version"
else
    report_fail "tpm-version"
fi

if tpm2_getcap properties-fixed > "${W}/getcap.log" 2>&1; then
    m="$(sed -n '/TPM2_PT_MANUFACTURER/,/value/s/.*value: *"\(.*\)".*/\1/p' "${W}/getcap.log" | head -n 1)"
    fw="$(sed -n '/TPM2_PT_FIRMWARE_VERSION_1/,/raw/s/.*raw: *\(0x[0-9A-Fa-f]*\).*/\1/p' "${W}/getcap.log" | head -n 1)"
    info_msg "manufacturer '${m}' firmware ${fw}"
    if [ -n "${MANUFACTURER}" ] && [ "${m}" != "${MANUFACTURER}" ]; then
        info_msg "expected manufacturer '${MANUFACTURER}'"
        report_fail "getcap"
    else
        report_pass "getcap"
    fi
else
    cat "${W}/getcap.log"
    report_fail "getcap"
fi

check selftest tpm2_selftest --fulltest

check pcrread tpm2_pcrread sha256:0,1,2,3,4,5,6,7,"${PCR}",23

# PCR extend: new = SHA256(old || digest), computed here and compared
pcr_extend() {
    tpm2_pcrreset "${PCR}" || return 1
    old="$(pcr_value "${PCR}")"
    digest="$(printf 'tpm2 pcr-extend %s' "$$" | sha256sum | cut -d ' ' -f 1)"
    tpm2_pcrextend "${PCR}:sha256=${digest}" || return 1
    new="$(pcr_value "${PCR}")"
    want="$(printf '%s%s' "${old}" "${digest}" | hex2bin | sha256sum | cut -d ' ' -f 1)"
    info_msg "PCR ${PCR}: ${old} -> ${new} (expected ${want})"
    [ -n "${new}" ] && [ "${new}" = "${want}" ]
}
check pcr-extend pcr_extend

getrandom() {
    a="$(tpm2_getrandom --hex 32)" || return 1
    b="$(tpm2_getrandom --hex 32)" || return 1
    info_msg "random: ${a} ${b}"
    [ "${#a}" -eq 64 ] && [ "${#b}" -eq 64 ] && [ "${a}" != "${b}" ]
}
check getrandom getrandom

cd "${W}" || exit 1
printf 'tpm2 test message %s\n' "$$" > msg
printf 'tpm2 test message %s!\n' "$$" > msg-tampered

key_sign_verify() {
    tpm2_createprimary -Q -C o -g sha256 -G ecc -c primary.ctx &&
    tpm2_create -Q -C primary.ctx -G ecc256:ecdsa -u key.pub -r key.priv &&
    tpm2_load -Q -C primary.ctx -u key.pub -r key.priv -c key.ctx &&
    tpm2_sign -Q -c key.ctx -g sha256 -o sig msg &&
    tpm2_verifysignature -Q -c key.ctx -g sha256 -m msg -s sig
}
check key-sign-verify key_sign_verify
if [ -e sig ]; then
    check_fails negative-verify-tampered tpm2_verifysignature -Q -c key.ctx -g sha256 -m msg-tampered -s sig
else
    report_skip negative-verify-tampered
fi

nv_cycle() {
    tpm2_nvundefine -Q -C o "${NV_INDEX}" > /dev/null 2>&1
    head -c 32 /dev/urandom > nv.in
    tpm2_nvdefine -Q -C o -s 32 -a "ownerread|ownerwrite" "${NV_INDEX}" &&
    tpm2_nvwrite -Q -C o -i nv.in "${NV_INDEX}" &&
    tpm2_nvread -Q -C o -s 32 -o nv.out "${NV_INDEX}" &&
    cmp nv.in nv.out &&
    tpm2_nvundefine -Q -C o "${NV_INDEX}"
}
check nv-define-write-read nv_cycle
tpm2_nvundefine -Q -C o "${NV_INDEX}" > /dev/null 2>&1
check_fails negative-nvread-undefined tpm2_nvread -Q -C o -s 32 -o nv.none "${NV_INDEX}"

NONCE="$(tpm2_getrandom --hex 16)"
quote() {
    tpm2_create -Q -C primary.ctx -G ecc256:ecdsa-sha256:null -u ak.pub -r ak.priv \
        -a "fixedtpm|fixedparent|sensitivedataorigin|userwithauth|restricted|sign" &&
    tpm2_load -Q -C primary.ctx -u ak.pub -r ak.priv -c ak.ctx &&
    tpm2_readpublic -Q -c ak.ctx -f pem -o ak.pem &&
    tpm2_quote -Q -c ak.ctx -l "sha256:0,${PCR},17,23" -q "${NONCE}" -m quote.msg \
        -s quote.sig -o quote.pcrs -g sha256 &&
    tpm2_checkquote -Q -u ak.pem -m quote.msg -s quote.sig -f quote.pcrs -g sha256 -q "${NONCE}"
}
check quote quote
if [ -e quote.msg ]; then
    check_fails negative-quote-nonce tpm2_checkquote -Q -u ak.pem -m quote.msg -s quote.sig \
        -f quote.pcrs -g sha256 -q "$(tpm2_getrandom --hex 16)"
else
    report_skip negative-quote-nonce
fi

# PCR 17 is the D-RTM PCR: only locality 4 can reset it, never locality 0
check_fails negative-pcr17-reset tpm2_pcrreset 17

if [ -n "${LOCALITY_DENIED}" ]; then
    mount | grep -q debugfs || mount -t debugfs debugfs /sys/kernel/debug
    if [ -w "${LOCALITY_FILE}" ]; then
        echo "${LOCALITY_DENIED}" > "${LOCALITY_FILE}"
        info_msg "kernel locality now $(cat "${LOCALITY_FILE}")"
        check_fails locality-denied tpm2_getrandom --hex 8
        echo 0 > "${LOCALITY_FILE}"
        check locality-0-after-denied tpm2_getrandom --hex 8
        dmesg | grep -i -E 'tpm|optee' | tail -n 5
    else
        info_msg "no ${LOCALITY_FILE}"
        report_fail locality-denied
        report_skip locality-0-after-denied
    fi
else
    report_skip locality-denied
    report_skip locality-0-after-denied
fi

if [ -n "${PCR17_SHA256}" ]; then
    p17="$(pcr_value 17)"
    info_msg "PCR 17: ${p17} (expected ${PCR17_SHA256})"
    if [ "${p17}" = "$(echo "${PCR17_SHA256}" | tr 'A-F' 'a-f')" ]; then
        report_pass pcr17-locality4
    else
        report_fail pcr17-locality4
    fi
else
    info_msg "PCR 17: $(pcr_value 17)"
    report_skip pcr17-locality4
fi

cd / && rm -rf "${W}"
