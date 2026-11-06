#!/bin/sh
set -x
# shellcheck disable=SC1091
. ../../lib/sh-test-lib

OUTPUT="$(pwd)/output"
RESULT_FILE="${OUTPUT}/result.txt"
RESULT_LOG="${OUTPUT}/result_log.txt"
SKIP_INSTALL="false"
SMP="true"
GIT_REF="master"
RESULTS="tap"
CPUS=""
REQUIRE_KVM="false"
QEMU="auto"
QEMU_DIR="/opt/kvm-unit-tests-qemu"
QEMU_LOG="${OUTPUT}/result_log_qemu.txt"

usage() {
    echo "Usage: $0 [-s <true|false>]
                    [-m <true|false>]
                    [-g git-reference]
                    [-r <tap|test>]
                    [-c <host cpu list>]
                    [-k <true|false>]
                    [-q <auto|true|false>]
                    [-Q <kvm-unit-tests for QEMU dir>]" 1>&2
    exit 1
}

while getopts "s:m:g:r:c:k:q:Q:h" o; do
  case "$o" in
    s) SKIP_INSTALL="${OPTARG}" ;;
    m) SMP="${OPTARG}" ;;
    g) GIT_REF="${OPTARG}" ;;
    r) RESULTS="${OPTARG}" ;;
    c) CPUS="${OPTARG}" ;;
    k) REQUIRE_KVM="${OPTARG}" ;;
    q) QEMU="${OPTARG}" ;;
    Q) QEMU_DIR="${OPTARG}" ;;
    h|*) usage ;;
  esac
done

uncolour() {
    sed "s/$(printf '\033')\[[0-9;]*m//g" "$@"
}

# The runner's verdict lines ("PASS|FAIL|SKIP <test> ...", coloured) of a
# log (default RESULT_LOG) as "<test> pass|fail|skip"
verdicts() {
    uncolour "${1:-${RESULT_LOG}}" |
        awk '$1 ~ /^(PASS|FAIL|SKIP)$/ && NF >= 2 { print $2, tolower($1) }'
}

# The tests a run skipped because they need QEMU (unittests.cfg
# disabled_if [[ "$TARGET" != qemu ]]): verdict lines, or TAP skip lines.
qemu_only() {
    uncolour "${RESULT_LOG}" | awk '/!= *qemu/ {
        if ($1 == "SKIP") print $2
        else if ($1 == "ok" && $3 == "-") { sub(/:$/, "", $4); print $4 } }' | sort -u
}

# RESULT_LOG without the skip lines of the tests run again under QEMU.
kvmtool_log() {
    uncolour "${RESULT_LOG}" | awk -v t=" ${QEMU_TESTS} " '/!= *qemu/ {
        n = ($1 == "SKIP") ? $2 : ($1 == "ok" && $3 == "-") ? $4 : ""
        sub(/:$/, "", n)
        if (n != "" && index(t, " " n " ")) next } { print }'
}

parse_output() {
    # Parse input test names and results log to results file
    kvmtool_log > "${OUTPUT}/result_log_kvmtool.txt"
    if [ "${RESULTS}" = "test" ]; then
        verdicts "${OUTPUT}/result_log_kvmtool.txt" | tee -a "${RESULT_FILE}"
        [ -z "${QEMU_TESTS}" ] || verdicts "${QEMU_LOG}" | tee -a "${RESULT_FILE}"
    else
        ./parse-output.py < "${OUTPUT}/result_log_kvmtool.txt" | tee -a "${RESULT_FILE}"
        [ -z "${QEMU_TESTS}" ] || ./parse-output.py < "${QEMU_LOG}" | tee -a "${RESULT_FILE}"
    fi
}

# Hold this shell, and the VMs it starts, on the CPUs in CPUS: with taskset
# or, where that is missing (BusyBox), a cgroup v2 cpuset.
PIN=""
CG=""
CG_MOUNTED=""
pin_cpus() {
    if command -v taskset > /dev/null; then
        PIN="taskset -c ${CPUS}"
        return 0
    fi
    CG="$(awk '$3 == "cgroup2" { print $2; exit }' /proc/mounts)"
    if [ -z "${CG}" ] && mount -t cgroup2 none /sys/fs/cgroup; then
        CG=/sys/fs/cgroup
        CG_MOUNTED="${CG}"
    fi
    [ -n "${CG}" ] && grep -qw cpuset "${CG}/cgroup.controllers" &&
        echo +cpuset > "${CG}/cgroup.subtree_control" &&
        mkdir -p "${CG}/kvm-unit-tests" &&
        echo "${CPUS}" > "${CG}/kvm-unit-tests/cpuset.cpus" &&
        echo $$ > "${CG}/kvm-unit-tests/cgroup.procs"
}

unpin_cpus() {
    [ -z "${CG}" ] || [ ! -d "${CG}/kvm-unit-tests" ] ||
        { echo $$ > "${CG}/cgroup.procs"; rmdir "${CG}/kvm-unit-tests"; }
    [ -z "${CG_MOUNTED}" ] || umount "${CG_MOUNTED}"
}

kvm_unit_tests_run_test() {
    info_msg "running kvm unit tests ..."
    # BusyBox has no getconf, and its timeout lacks the --foreground option
    # the run scripts use: count the CPUs with nproc, and run the tests
    # without their own time limit (the test job's timeout still applies).
    if ! command -v getconf > /dev/null; then
        MAX_SMP="$(nproc)"
        export MAX_SMP
    fi
    if ! timeout --foreground 1 true 2> /dev/null; then
        warn_msg "no timeout --foreground: per-test time limits disabled"
        TIMEOUT=0
        export TIMEOUT
    fi
    flags="-a -t -v"
    [ "${RESULTS}" = "test" ] && flags="-a -v"
    [ "${SMP}" = "false" ] && [ -z "${CPUS}" ] && CPUS=0
    if [ -n "${CPUS}" ] && ! pin_cpus; then
        warn_msg "cannot hold the VMs on CPUs ${CPUS}"
    fi
    # shellcheck disable=SC2086
    ${PIN} ./run_tests.sh ${flags} | tee -a "${RESULT_LOG}"
    # The output of each failed test
    verdicts | awk '$2 == "fail" { print $1 }' | while read -r t; do
        info_msg "${t} log:"
        cat "logs/${t}.log"
    done
    kvm_unit_tests_run_qemu "${flags}"
    unpin_cpus
}

# The tests the kvmtool run skipped as QEMU only (PCI test device, live
# migration), run again with the copy built for QEMU on qemu-system-aarch64
# with KVM, on the same CPUs.
QEMU_TESTS=""
kvm_unit_tests_run_qemu() {
    case "${QEMU}" in false|False) return 0 ;; esac
    tests="$(qemu_only | tr '\n' ' ')"
    [ -n "${tests}" ] || return 0
    if [ ! -x "${QEMU_DIR}/run_tests.sh" ] || ! command -v qemu-system-aarch64 > /dev/null; then
        info_msg "no qemu-system-aarch64 or ${QEMU_DIR}: the QEMU only tests stay skipped (${tests})"
        case "${QEMU}" in true|True) report_fail "qemu-available" ;; esac
        return 0
    fi
    case "${QEMU}" in true|True) report_pass "qemu-available" ;; esac
    QEMU_TESTS="${tests}"
    info_msg "running the QEMU only tests under $(qemu-system-aarch64 --version | head -n 1): ${tests}"
    (
        cd "${QEMU_DIR}" || exit 1
        # shellcheck disable=SC2086
        ${PIN} ./run_tests.sh $1 ${tests} | tee "${QEMU_LOG}"
        verdicts "${QEMU_LOG}" | awk '$2 == "fail" { print $1 }' | while read -r t; do
            info_msg "${t} (QEMU) log:"
            cat "logs/${t}.log"
        done
    )
}

kvm_unit_tests_build_test() {
    info_msg "git clone kvm unit tests ..."
    git clone https://gitlab.com/kvm-unit-tests/kvm-unit-tests.git
    cd kvm-unit-tests || error_msg "Wasn't able to clone repo kvm-unit-tests!"
    info_msg "Checkout on a given git reference ${GIT_REF}"
    git checkout "${GIT_REF}"
    retval=$?
    if [ $retval -ne 0 ]; then
        error_msg "SHA or branch: ${GIT_REF} not found!"
    fi

    info_msg "configure kvm unit tests ..."
    ./configure
    info_msg "make kvm unit tests ..."
    make || true
}

install() {
    dist_name
    # shellcheck disable=SC2154
    case "${dist}" in
      debian|ubuntu)
        pkgs="binutils gcc make python sed tar wget"
        ;;
      fedora|centos)
        pkgs="binutils gcc glibc-static make python sed tar wget"
        ;;
    esac
    install_deps "${pkgs}" "${SKIP_INSTALL}"
}

# Test run.
! check_root && error_msg "This script must be run as root"
create_out_dir "${OUTPUT}"

info_msg "About to run kvm unit tests ..."
info_msg "Output directory: ${OUTPUT}"


if [ "${SKIP_INSTALL}" = "True" ] || [ "${SKIP_INSTALL}" = "true" ]; then
    info_msg "Dependency installation for kvm-unit-tests skipped"
else
  # Install packages
  install
fi

if [ "${REQUIRE_KVM}" = "true" ] || [ "${REQUIRE_KVM}" = "True" ]; then
    if [ -c /dev/kvm ]; then
        report_pass "kvm-device"
    else
        report_fail "kvm-device"
    fi
fi

# Build kvm unit tests if needed
if [ -f /opt/kvm-unit-tests/run_tests.sh ]; then
  cd /opt/kvm-unit-tests || exit 1
else
  kvm_unit_tests_build_test
fi

# Run kvm unit tests
kvm_unit_tests_run_test
cd - || exit 1

# Parse and print kvm unit tests results
parse_output
