#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Qualcomm Technologies, Inc. and/or its subsidiaries.
#
# Protected KVM guests (kvm-arm.mode=protected) with the upstream VMM path,
# kvmtool "lkvm run --protected", and their isolation from the host, each
# with the same check on a normal guest as the negative control:
#
#   npvm-*  normal guest: boots, runs the workload, and the host reads the
#           guest's secret through /proc/<lkvm>/mem (the control proves the
#           probe works); it then shuts down cleanly.
#   pvm-*   protected guest: boots with the restricted DMA pool, runs the
#           workload and shuts down cleanly (kvmtool exits 0).
#   pvmpeek-*  protected guest whose memory the host reads the same way:
#           every page of guest RAM is read or unreadable, none holds the
#           secret, and the guest cannot run on (kvmtool fails).
#   probe   pvm-probe, a minimal VMM: its own read of the guest's memory
#           faults (SIGSEGV, SEGV_ACCERR) and the guest runs on with its
#           data intact; an IPA outside its memory is MMIO to the VMM, and
#           FF-A and SMC are not available to it.
#
# The guest's init prints "kvm-guest: ready ..." with its vCPU count,
# kernel release and number of restricted DMA pools.

# shellcheck disable=SC1091
. ../../lib/sh-test-lib
OUTPUT="$(pwd)/output"
RESULT_FILE="${OUTPUT}/result.txt"
export RESULT_FILE

LKVM=""
KERNEL="$(pwd)/guest/Image"
INITRD="$(pwd)/guest/initramfs.cpio.gz"
GUEST_FP=""
VCPUS="2"
MEMORY="256"
TIMEOUT="90"

usage() {
    echo "Usage: $0 [-l <lkvm>] [-k <kernel>] [-i <initramfs>] [-f <guest kernel fp>]" 1>&2
    echo "          [-c <vcpus>] [-m <memory MiB>] [-t <timeout s>]" 1>&2
    exit 1
}

while getopts "l:k:i:f:c:m:t:h" o; do
    case "$o" in
        l) LKVM="${OPTARG}" ;;
        k) KERNEL="${OPTARG}" ;;
        i) INITRD="${OPTARG}" ;;
        f) GUEST_FP="${OPTARG}" ;;
        c) VCPUS="${OPTARG}" ;;
        m) MEMORY="${OPTARG}" ;;
        t) TIMEOUT="${OPTARG}" ;;
        h|*) usage ;;
    esac
done
# The kvmtool built with the test (master, lkvm run --protected) unless
# one is given; a distribution lkvm may predate --protected.
if [ -z "${LKVM}" ]; then
    if [ -x ./lkvm ]; then LKVM="$(pwd)/lkvm"; else LKVM="lkvm"; fi
fi

# pid_of <comm>: first process with that name (no pgrep on minimal rootfs)
pid_of() {
    for d in /proc/[0-9]*; do
        [ "$(cat "${d}/comm" 2> /dev/null)" = "$1" ] && { echo "${d#/proc/}"; return 0; }
    done
    return 1
}

# Centiseconds since boot
now() {
    tr -d . < /proc/uptime | cut -d ' ' -f 1
}

# wait_for <pattern>: until the console shows <pattern> (0), kvmtool exits
# (1) or TIMEOUT seconds pass (2)
wait_for() {
    local end
    end=$(($(now) + TIMEOUT * 100))
    while ! tr -d '\r' < "${CONSOLE}" | grep -q "$1"; do
        kill -0 "${pid}" 2> /dev/null || return 1
        [ "$(now)" -lt "${end}" ] || return 2
        sleep 0.1
    done
}

# wait_exit: until kvmtool exits (0) or TIMEOUT seconds pass (1)
wait_exit() {
    local end
    end=$(($(now) + TIMEOUT * 100))
    while kill -0 "${pid}" 2> /dev/null; do
        [ "$(now)" -lt "${end}" ] || return 1
        sleep 0.1
    done
}

check() {
    if [ "$2" = 0 ]; then report_pass "$1"; else report_fail "$1"; fi
}

# start_guest <tag> [lkvm options]: kvmtool on a pty (it reads console
# input only from a terminal), console input from a FIFO held open on fd 3
start_guest() {
    TAG="$1"
    shift
    CONSOLE="${OUTPUT}/${TAG}-console.log"
    FIFO="${OUTPUT}/${TAG}-console.in"
    VMM="${OUTPUT}/${TAG}-vmm.sh"
    NONCE="$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')"
    cat > "${VMM}" << EOF
#!/bin/sh
"${LKVM}" run --kernel "${KERNEL}" --initrd "${INITRD}" --cpus "${VCPUS}" \\
    --mem "${MEMORY}" --console virtio --network mode=none \\
    --virtio-transport pci --no-pvtime $* --params "quiet pvmtest.nonce=${NONCE}"
echo "kvm-guest: vmm exit status \$?"
EOF
    chmod 755 "${VMM}"
    mkfifo "${FIFO}"
    exec 3<> "${FIFO}"
    start="$(now)"
    socat STDIO "EXEC:${VMM},pty,setsid,ctty,stderr" < "${FIFO}" > "${CONSOLE}" 2>&1 &
    pid=$!
    wait_for "kvm-guest: ready"
    rc=$?
    ready="$(now)"
    if [ "${rc}" -ne 0 ]; then
        [ "${rc}" -eq 2 ] && kill "${pid}"
        wait "${pid}"
        cat "${CONSOLE}"
        report_fail "${TAG}-boot"
        exec 3>&-
        return 1
    fi
    line="$(tr -d '\r' < "${CONSOLE}" | grep -m 1 "kvm-guest: ready")"
    info_msg "${TAG}: ${line}"
    add_metric "${TAG}-boot" "pass" \
        "$(((ready - start) / 100)).$(printf '%02d' $(((ready - start) % 100)))" "seconds"
    if [ -n "${GUEST_FP}" ]; then
        echo "${line}" | grep -E -q "release=[^ ]*-${GUEST_FP}[+]? "
        check "${TAG}-guest-fingerprint" $?
    fi
    # The guest's secret: derived from the nonce at run time, so the
    # string is in neither the initramfs nor the guest command line.
    SECRET="pvmsecret-$((NONCE * 7))"
    # shellcheck disable=SC2016
    echo 'S=pvmsecret-$((${NONCE:-0} * 7)); yes $S | head -c 8388608 > /tmp/secret; echo "secret-ready $(sha256sum < /tmp/secret | cut -c1-64)"' >&3
    want="$(yes "${SECRET}" | head -c 8388608 | sha256sum | cut -c1-64)"
    if wait_for "^secret-ready ${want}"; then
        report_pass "${TAG}-workload"
    else
        report_fail "${TAG}-workload"
    fi
    return 0
}

# stop_guest <tag> <expected kvmtool status: 0 or nonzero>
stop_guest() {
    echo "poweroff -f" >&3
    if ! wait_exit; then
        info_msg "kvmtool still running ${TIMEOUT} s after poweroff"
        kill "${pid}"
    fi
    wait "${pid}"
    exec 3>&-
    rc="$(tr -d '\r' < "${CONSOLE}" | sed -n 's/^kvm-guest: vmm exit status //p')"
    info_msg "$1: kvmtool exit status ${rc:-unknown}"
    if [ "$2" = 0 ]; then
        [ "${rc}" = 0 ]
    else
        [ -n "${rc}" ] && [ "${rc}" != 0 ]
    fi
    check "$1-shutdown" $?
    cat "${CONSOLE}"
}

# peek <tag>: the host reads the guest's RAM through /proc/<lkvm>/mem
peek() {
    lp="$(pid_of lkvm)"
    out="$(./procmem-scan "${lp}" "${MEMORY}" "${SECRET}")"
    info_msg "$1: procmem-scan lkvm ${lp}: ${out}"
    hits="$(echo "${out}" | sed -n 's/.* hits=\([0-9]*\).*/\1/p')"
    covered="$(echo "${out}" | sed -n 's/.* covered=\([0-9]*\).*/\1/p')"
    total="$(echo "${out}" | sed -n 's/.* total=\([0-9]*\).*/\1/p')"
}

create_out_dir "${OUTPUT}"

if ! grep -q "kvm-arm.mode=protected" /proc/cmdline ||
   ! dmesg | grep -q "Protected [hn]VHE mode initialized successfully"; then
    info_msg "pKVM is not enabled (kvm-arm.mode=protected)"
    report_fail "pkvm-enabled"
    exit 0
fi
report_pass "pkvm-enabled"
for f in "${KERNEL}" "${INITRD}" ./pvm-probe ./procmem-scan; do
    [ -f "${f}" ] || { info_msg "missing ${f}"; report_fail "prerequisites"; exit 0; }
done
command -v "${LKVM}" > /dev/null && command -v socat > /dev/null ||
    { info_msg "needs ${LKVM} and socat"; report_fail "prerequisites"; exit 0; }
report_pass "prerequisites"
[ -d "${HOME:-}" ] || export HOME=/tmp
info_msg "lkvm $("${LKVM}" version 2>&1 | head -n 1)"
# KSM merging would take a protected guest's pages back from it.
echo 0 > /sys/kernel/mm/ksm/run 2> /dev/null || true

DMESG0="$(dmesg | wc -l)"

# Minimal VMM first: no kvmtool involved.
for m in "" "-p"; do
    ./pvm-probe ${m} 2> "${OUTPUT}/probe${m}.log" | tee -a "${RESULT_FILE}"
    cat "${OUTPUT}/probe${m}.log"
    # A probe that stops early must not leave its cases unreported.
    t="npvm"; [ -n "${m}" ] && t="pvm"
    for c in create guest-ready host-read guest-intact guest-done secure-ipa ffa-hvc smc; do
        grep -q "^${t}-${c} " "${RESULT_FILE}" || report_fail "${t}-${c}"
    done
done

# Negative control: a normal guest's memory is visible to the host.
if start_guest npvm; then
    peek npvm
    [ "${hits:-0}" -gt 0 ]
    check "npvm-host-read-visible" $?
    stop_guest npvm 0
fi

if start_guest pvm --protected; then
    tr -d '\r' < "${CONSOLE}" | grep -q "kvm-guest: ready .* rdma=[1-9]"
    check "pvm-restricted-dma" $?
    stop_guest pvm 0
fi
dmesg | grep -q "protected VMs are experimental"
check "pvm-host-taint-notice" $?

if start_guest pvmpeek --protected; then
    peek pvmpeek
    # No secret anywhere in guest RAM: a scan that stopped early proves nothing.
    [ "${hits:-1}" -eq 0 ] && [ -n "${total}" ] && [ "${total}" -gt 0 ] &&
        [ "${covered:-0}" -eq "${total}" ]
    check "pvmpeek-host-read-secret-hidden" $?
    # The pages the host read went back to it zeroed: the guest cannot
    # use them any more, so it cannot run on.
    echo 'echo "guest-alive: $((6 * 7))"' >&3
    ! wait_for "^guest-alive: 42"
    check "pvmpeek-guest-stopped" $?
    stop_guest pvmpeek 1
fi

# Only what the host logged during the test counts.
if dmesg | tail -n "+$((DMESG0 + 1))" | grep -E -q "Unable to handle kernel|Internal error:|Call trace:"; then
    dmesg | tail -n "+$((DMESG0 + 1))" | grep -E -A20 "Unable to handle kernel|Internal error:|Call trace:"
    report_fail "host-no-oops"
else
    report_pass "host-no-oops"
fi
