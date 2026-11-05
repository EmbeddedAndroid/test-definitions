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
TESTS=""
ROUNDS=1

usage() {
    echo "Usage: $0 [-s <true|false>]
                    [-m <true|false>]
                    [-g git-reference]
                    [-r <tap|test>]
                    [-c <host cpu list>]
                    [-k <true|false>]
                    [-T "<test> ..."]
                    [-n <rounds>]" 1>&2
    exit 1
}

while getopts "s:m:g:r:c:k:T:n:h" o; do
  case "$o" in
    s) SKIP_INSTALL="${OPTARG}" ;;
    m) SMP="${OPTARG}" ;;
    g) GIT_REF="${OPTARG}" ;;
    r) RESULTS="${OPTARG}" ;;
    c) CPUS="${OPTARG}" ;;
    k) REQUIRE_KVM="${OPTARG}" ;;
    T) TESTS="${OPTARG}" ;;
    n) ROUNDS="${OPTARG}" ;;
    h|*) usage ;;
  esac
done

# The runner's verdict lines ("PASS|FAIL|SKIP <test> ...", coloured) of
# a log as "<test> pass|fail|skip"
verdicts() {
    sed "s/$(printf '\033')\[[0-9;]*m//g" "${1:-${RESULT_LOG}}" |
        awk '$1 ~ /^(PASS|FAIL|SKIP)$/ && NF >= 2 { print $2, tolower($1) }'
}

# One verdict per test over all rounds, in run order: fail if any round
# failed, else pass if any passed, else skip.
round_verdicts() {
    verdicts | awk '
        !($1 in v) { order[n++] = $1; v[$1] = $2; next }
        $2 == "fail" || ($2 == "pass" && v[$1] == "skip") { v[$1] = $2 }
        END { for (i = 0; i < n; i++) print order[i], v[order[i]] }'
}

parse_output() {
    # Parse input test names and results log to results file
    if [ "${RESULTS}" = "test" ]; then
        round_verdicts | tee -a "${RESULT_FILE}"
    else
        ./parse-output.py < "${RESULT_LOG}" | tee -a "${RESULT_FILE}"
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
    round=1
    while [ "${round}" -le "${ROUNDS}" ]; do
        [ "${ROUNDS}" -eq 1 ] || info_msg "round ${round} of ${ROUNDS}"
        # shellcheck disable=SC2086
        ${PIN} ./run_tests.sh ${flags} ${TESTS} | tee "${OUTPUT}/round.txt"
        cat "${OUTPUT}/round.txt" >> "${RESULT_LOG}"
        # The output of each failed test, before the next round replaces it
        verdicts "${OUTPUT}/round.txt" | awk '$2 == "fail" { print $1 }' | while read -r t; do
            info_msg "${t} log (round ${round}):"
            cat "logs/${t}.log"
        done
        round=$((round + 1))
    done
    unpin_cpus
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
