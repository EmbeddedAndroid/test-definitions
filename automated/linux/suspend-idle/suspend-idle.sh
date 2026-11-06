#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Qualcomm Technologies, Inc. and/or its subsidiaries.
#
# CPU and cluster idle residency, then system suspend and resume.
#
# Idle: the cpuidle counters of every online CPU and the idle states of the
# PSCI power domains (genpd, debugfs) are read before and after IDLE_SECONDS
# of an idle system. Each state reports its entries, its residency and the
# entries the platform refused (cpuidle "rejected", genpd "Rejected"). A
# cpuidle state fails when it is never entered or when the platform refuses
# it more often than it enters it; a CPU or cluster domain fails when it
# reaches none of its states (genpd counts what Linux requests, the
# refusals of the firmware show in the cpuidle counters). IDLE_SKIP exempts
# a state or domain, with the reason.
# The PSCI mode (OS-initiated or platform-coordinated) the kernel uses is
# reported, and checked against PSCI_MODE when it is set.
#
# Suspend: CYCLES suspends to each mode of MODES (mem_sleep values, empty
# for the kernel default), each woken by the RTC alarm after SLEEP seconds.
# A cycle fails if the suspend write fails or is not counted as a success,
# if the RTC alarm is not what woke it, if a bound device, an online CPU or
# a running remoteproc is missing after the resume, if a remoteproc crashed,
# or if the kernel logs a warning, oops or suspend error. In s2idle every
# CPU must have stayed in its deepest idle state for at least half of the
# suspend (a refused entry returns at once, so entries alone prove nothing).
# Entry and resume times come from the kernel log. Without a system sleep
# state or an RTC with a wake alarm the suspend cases are skipped with the
# reason (failed with REQUIRE_SUSPEND=true).

# shellcheck disable=SC1091
. ../../lib/sh-test-lib
OUTPUT="$(pwd)/output"
RESULT_FILE="${OUTPUT}/result.txt"
export RESULT_FILE

CYCLES=3
SLEEP=10
MODES=""
IDLE_SECONDS=30
PSCI_MODE=""
IDLE_SKIP=""
REQUIRE_SUSPEND="false"
# idle, suspend or both: the definition runs the phases one at a time and
# sends the results of each to LAVA before the next, so the idle results
# survive a suspend that never returns.
PHASE="idle suspend"

usage() {
    echo "Usage: $0 [-c <cycles>] [-s <sleep seconds>] [-m <mem_sleep modes>]
                    [-i <idle seconds>] [-p <osi|pc>]
                    [-x <state=reason;...>] [-r <true|false>]
                    [-P <idle|suspend|both, space separated>]" 1>&2
    exit 1
}

while getopts "c:s:m:i:p:x:r:P:h" o; do
    case "$o" in
        c) CYCLES="${OPTARG}" ;;
        s) SLEEP="${OPTARG}" ;;
        m) MODES="${OPTARG}" ;;
        i) IDLE_SECONDS="${OPTARG}" ;;
        p) PSCI_MODE="${OPTARG}" ;;
        x) IDLE_SKIP="${OPTARG}" ;;
        r) REQUIRE_SUSPEND="${OPTARG}" ;;
        P) PHASE="${OPTARG}" ;;
        h|*) usage ;;
    esac
done

# The kernel interfaces read, overridable to run the script on a copy.
SYS_CPU="${SYS_CPU:-/sys/devices/system/cpu}"
GENPD="${GENPD:-/sys/kernel/debug/pm_genpd}"
SYS_POWER="${SYS_POWER:-/sys/power}"
SYS_BUS="${SYS_BUS:-/sys/bus}"
RTC_CLASS="${RTC_CLASS:-/sys/class/rtc}"
REMOTEPROC_CLASS="${REMOTEPROC_CLASS:-/sys/class/remoteproc}"
W="${OUTPUT}/work"

create_out_dir "${OUTPUT}"
mkdir -p "${W}"

# Lower case, every run of other characters a single '-'.
slug() {
    echo "$1" | tr 'A-Z' 'a-z' | sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-//' -e 's/-$//'
}

# The reason IDLE_SKIP gives for a state ("<state>=<reason>;..."), if any.
skip_reason() {
    echo "${IDLE_SKIP}" | tr ';' '\n' | sed -n "s|^ *$1 *= *||p" | head -n 1
}

uptime_cs() {
    awk '{ split($1, a, "."); printf "%d\n", a[1] * 100 + substr(a[2] "00", 1, 2) }' /proc/uptime
}

online_cpus() {
    for d in "${SYS_CPU}"/cpu[0-9]*; do
        [ -f "${d}/online" ] && [ "$(cat "${d}/online")" != 1 ] && continue
        echo "${d##*/}"
    done
}

# ---------------------------------------------------------------------------
# PSCI mode
# ---------------------------------------------------------------------------
psci_mode() {
    if dmesg | grep -q "CPU PM domain topology using OSI mode"; then
        echo osi
    elif dmesg | grep -q "CPU PM domain topology using PC mode"; then
        echo pc
    elif [ -d "${SYS_CPU}/cpu0/cpuidle" ]; then
        # cpuidle-psci without a domain topology coordinates platform-wise.
        echo pc
    fi
}

phase() {
    case " ${PHASE} " in *" $1 "*) return 0 ;; esac
    return 1
}

mode="$(psci_mode)"
info_msg "PSCI CPU idle coordination: ${mode:-unknown}"
if ! phase idle; then
    :
elif [ -n "${PSCI_MODE}" ]; then
    if [ "${mode}" = "${PSCI_MODE}" ]; then
        report_pass "psci-mode"
    else
        warn_msg "PSCI mode ${mode:-unknown}, expected ${PSCI_MODE}"
        report_fail "psci-mode"
    fi
elif [ -n "${mode}" ]; then
    report_pass "psci-mode-${mode}"
fi

# ---------------------------------------------------------------------------
# Snapshots
# ---------------------------------------------------------------------------
# One line per online CPU and cpuidle state:
#   <cpu> <state dir> <name> <usage> <time us> <rejected> <disable> <s2idle usage>
#   <s2idle time us>
snap_cpuidle() {
    for c in $(online_cpus); do
        for d in "${SYS_CPU}/${c}"/cpuidle/state[0-9]*; do
            [ -d "${d}" ] || continue
            s2=-
            s2t=-
            [ -r "${d}/s2idle/usage" ] && s2="$(cat "${d}/s2idle/usage")"
            [ -r "${d}/s2idle/time" ] && s2t="$(cat "${d}/s2idle/time")"
            printf '%s %s %s %s %s %s %s %s %s\n' "${c}" "${d##*/}" \
                "$(sed 's/[^A-Za-z0-9_.-]/_/g' "${d}/name")" \
                "$(cat "${d}/usage")" "$(cat "${d}/time")" \
                "$(cat "${d}/rejected" 2>/dev/null || echo 0)" \
                "$(cat "${d}/disable" 2>/dev/null || echo 0)" "${s2}" "${s2t}"
        done
    done
}

# The PSCI power domains: the genpd domains a CPU is attached to and every
# domain above them.
psci_domains() {
    [ -d "${GENPD}" ] || return 0
    doms=""
    for d in "${GENPD}"/*/; do
        d="${d%/}"
        # cpuidle-psci attaches each CPU through a virtual device, genpd:0:cpuN
        grep -qE '(^|[/:])cpu[0-9]+$' "${d}/devices" 2>/dev/null && doms="${doms} ${d##*/}"
    done
    while :; do
        n=$(echo "${doms}" | wc -w)
        for d in "${GENPD}"/*/; do
            d="${d%/}"
            case " ${doms} " in *" ${d##*/} "*) continue ;; esac
            for s in $(cat "${d}/sub_domains" 2>/dev/null); do
                case " ${doms} " in *" ${s} "*) doms="${doms} ${d##*/}"; break ;; esac
            done
        done
        [ "$(echo "${doms}" | wc -w)" -eq "${n}" ] && break
    done
    echo "${doms}"
}

# One line per PSCI domain idle state:
#   <domain> <state> <usage> <time ms> <rejected> <s2idle usage>
snap_genpd() {
    for dom in ${DOMAINS}; do
        awk -v d="${dom}" 'NR > 1 && NF >= 4 {
            printf "%s %s %s %s %s %s\n", d, $1, $3, $2, $4, (NF >= 7 ? $7 : "-") }' \
            "${GENPD}/${dom}/idle_states"
    done
}

if [ ! -d "${GENPD}" ] && [ "${GENPD}" = /sys/kernel/debug/pm_genpd ]; then
    mount -t debugfs none /sys/kernel/debug 2>/dev/null
fi
DOMAINS="$(psci_domains)"
if [ -d "${GENPD}" ]; then
    info_msg "PSCI power domains:${DOMAINS:- none} ($(ls "${GENPD}" | wc -l) genpd domains in ${GENPD})"
else
    info_msg "no ${GENPD} (debugfs or CONFIG_PM_GENERIC_DOMAINS): PSCI domain states not read"
fi

# ---------------------------------------------------------------------------
# Idle residency
# ---------------------------------------------------------------------------
idle_report() {
    window_us=$((IDLE_SECONDS * 1000000))
    # Per state name: CPUs with it, CPUs that entered it, entries, residency
    # in us, refused entries, CPUs where it is disabled.
    awk 'NR == FNR { u[$1 " " $2] = $4; t[$1 " " $2] = $5; r[$1 " " $2] = $6; next }
        ($1 " " $2) in u {
            n[$3]++; du = $4 - u[$1 " " $2]
            if (du > 0) e[$3]++
            us[$3] += du; ti[$3] += $5 - t[$1 " " $2]; rj[$3] += $6 - r[$1 " " $2]
            if ($7 != 0) dis[$3]++
            if (!($3 in o)) { o[$3] = ++k; nm[k] = $3 }
        }
        END { for (i = 1; i <= k; i++) { s = nm[i]
            printf "%s %d %d %.0f %.0f %.0f %d\n", s, n[s], e[s], us[s], ti[s], rj[s], dis[s] } }' \
        "${W}/cpuidle.0" "${W}/cpuidle.1" > "${W}/cpuidle.delta"
    info_msg "cpuidle over ${IDLE_SECONDS} s idle (state cpus entered usage time-us rejected disabled):"
    cat "${W}/cpuidle.delta"
    while read -r name n entered usage time rejected disabled; do
        c="cpuidle-$(slug "${name}")"
        add_metric "${c}-usage" pass "${usage}" entries
        add_metric "${c}-rejected" pass "${rejected}" entries
        add_metric "${c}-residency" pass \
            "$(awk -v t="${time}" -v n="${n}" -v w="${window_us}" 'BEGIN { printf "%.2f", t * 100 / (n * w) }')" "%"
        why="$(skip_reason "${name}")"
        if [ -n "${why}" ]; then
            info_msg "${name}: not required (${why})"
            report_skip "${c}-entered"
        elif [ "${disabled}" = "${n}" ]; then
            info_msg "${name}: disabled on every CPU"
            report_skip "${c}-entered"
        elif [ "${entered}" -gt 0 ]; then
            report_pass "${c}-entered"
        else
            warn_msg "${name}: never entered on ${n} CPUs (${rejected} entries refused)"
            report_fail "${c}-entered"
        fi
        # The platform refusing most requests for a state (PSCI CPU_SUSPEND
        # returning an error, counted by cpuidle as rejected) is a failure
        # even when some get through; occasional refusals (a racing wakeup
        # in OS-initiated mode) are not.
        if [ -z "${why}" ] && [ "${disabled}" != "${n}" ]; then
            if [ "${rejected}" -gt "${usage}" ]; then
                warn_msg "${name}: refused ${rejected} times, entered ${usage} times"
                report_fail "${c}-refused"
            else
                report_pass "${c}-refused"
            fi
        fi
    done < "${W}/cpuidle.delta"

    [ -n "${DOMAINS}" ] || return 0
    awk 'NR == FNR { u[$1 " " $2] = $3; t[$1 " " $2] = $4; r[$1 " " $2] = $5; next }
        ($1 " " $2) in u {
            printf "%s %s %.0f %.0f %.0f\n", $1, $2, $3 - u[$1 " " $2], $4 - t[$1 " " $2], $5 - r[$1 " " $2] }' \
        "${W}/genpd.0" "${W}/genpd.1" > "${W}/genpd.delta"
    info_msg "PSCI domain idle states over ${IDLE_SECONDS} s idle (domain state usage time-ms rejected):"
    cat "${W}/genpd.delta"
    # genpd counts the states Linux puts a domain in, not whether the
    # firmware accepted the CPU_SUSPEND that carried them (refusals show in
    # the cpuidle counters above), so the per-state numbers are
    # measurements. A CPU domain and a cluster domain (one whose
    # subdomains are CPU domains) must reach at least one of its states;
    # the domains above them (system) are measured only.
    while read -r dom st usage time rejected; do
        c="genpd-$(slug "${dom}")-$(slug "${st}")"
        add_metric "${c}-usage" pass "${usage}" entries
        add_metric "${c}-rejected" pass "${rejected}" entries
        add_metric "${c}-residency" pass \
            "$(awk -v t="${time}" -v w="${IDLE_SECONDS}" 'BEGIN { printf "%.2f", t / (w * 10) }')" "%"
    done < "${W}/genpd.delta"
    for dom in ${DOMAINS}; do
        kind=""
        grep -qE '(^|[/:])cpu[0-9]+$' "${GENPD}/${dom}/devices" 2>/dev/null && kind=cpu
        if [ -z "${kind}" ]; then
            for sd in $(cat "${GENPD}/${dom}/sub_domains" 2>/dev/null); do
                grep -qE '(^|[/:])cpu[0-9]+$' "${GENPD}/${sd}/devices" 2>/dev/null && kind=cluster
            done
        fi
        [ -n "${kind}" ] || continue
        c="genpd-$(slug "${dom}")-reached"
        reached="$(awk -v d="${dom}" '$1 == d && $3 > 0 { n++ } END { print n + 0 }' "${W}/genpd.delta")"
        why="$(skip_reason "${dom}")"
        if [ -n "${why}" ]; then
            info_msg "${dom}: not required (${why})"
            report_skip "${c}"
        elif [ "${reached}" -gt 0 ]; then
            report_pass "${c}"
        else
            warn_msg "${kind} domain ${dom}: none of its idle states reached"
            report_fail "${c}"
        fi
    done < "${W}/genpd.delta"
}

if ! phase idle; then
    :
elif [ -d "${SYS_CPU}/cpu0/cpuidle" ] || [ -n "$(ls -d "${SYS_CPU}"/cpu*/cpuidle 2>/dev/null)" ]; then
    sync
    sleep 2
    snap_cpuidle > "${W}/cpuidle.0"
    snap_genpd > "${W}/genpd.0"
    sleep "${IDLE_SECONDS}"
    snap_cpuidle > "${W}/cpuidle.1"
    snap_genpd > "${W}/genpd.1"
    idle_report
else
    info_msg "no cpuidle driver: idle residency not measured"
    report_skip "cpuidle"
fi

# ---------------------------------------------------------------------------
# Suspend and resume
# ---------------------------------------------------------------------------
skip_suspend() {
    if [ "${REQUIRE_SUSPEND}" = "true" ] || [ "${REQUIRE_SUSPEND}" = "True" ]; then
        warn_msg "$1"
        report_fail "suspend-supported"
    else
        info_msg "suspend not tested: $1"
        report_skip "suspend-supported"
    fi
}

# Bound devices, online CPUs and remoteproc states, one per line.
snap_devices() {
    for l in "${SYS_BUS}"/*/drivers/*/*; do
        [ -L "${l}" ] || continue
        case "${l##*/}" in module) continue ;; esac
        echo "dev ${l#"${SYS_BUS}"/}"
    done
    online_cpus | sed 's/^/cpu /'
    for r in "${REMOTEPROC_CLASS}"/remoteproc*; do
        [ -r "${r}/state" ] || continue
        echo "rproc $(cat "${r}/name" 2>/dev/null || echo "${r##*/}") $(cat "${r}/state")"
    done
}

# Seconds of the first kernel log line (in <file>) matching <regexp>.
log_time() {
    grep -E "$1" "$2" | sed -n 's/^\[ *\([0-9]*\.[0-9]*\)\].*/\1/p' | head -n 1
}

KERNEL_BAD='WARNING:|BUG:|Oops|nobody cared|Unable to handle|Call trace:|Internal error|PM: .*(failed|error)|Freezing .*failed|Some devices failed|could not suspend|timed out'
RPROC_CRASH='crash detected|fatal error received|watchdog received'

run_cycle() { # <mode> <cycle>
    cyc="suspend-$1-$2"
    snap_devices | sort > "${W}/dev.0"
    snap_cpuidle > "${W}/s2.0"
    [ -n "${DOMAINS}" ] && snap_genpd > "${W}/gs2.0"
    ok0="$(cat "${SYS_POWER}"/suspend_stats/success 2>/dev/null || echo -)"
    l0="$(dmesg | wc -l)"
    echo 0 > "${RTC}/wakealarm"
    echo "+${SLEEP}" > "${RTC}/wakealarm"
    info_msg "${cyc}: suspending, RTC alarm in ${SLEEP} s"
    t0="$(uptime_cs)"
    rc=0
    if ! echo "${STATE}" > "${SYS_POWER}"/state; then
        rc=1
    fi
    t1="$(uptime_cs)"
    # The RTC core disables the alarm once it has fired: a pending alarm
    # after the resume means something else woke the system.
    alarm="$(cat "${RTC}/wakealarm" 2>/dev/null)"
    echo 0 > "${RTC}/wakealarm"
    sleep 2
    dmesg | sed "1,${l0}d" > "${W}/${cyc}.log"
    ok1="$(cat "${SYS_POWER}"/suspend_stats/success 2>/dev/null || echo -)"
    snap_devices | sort > "${W}/dev.1"
    snap_cpuidle > "${W}/s2.1"
    [ -n "${DOMAINS}" ] && snap_genpd > "${W}/gs2.1"
    add_metric "${cyc}-duration" pass "$(awk -v a="${t0}" -v b="${t1}" 'BEGIN { printf "%.2f", (b - a) / 100 }')" s

    if [ "${rc}" -eq 0 ] && { [ "${ok0}" = - ] || [ "${ok1}" -gt "${ok0}" ]; }; then
        report_pass "${cyc}"
    else
        warn_msg "${cyc}: write ${STATE} failed (${rc}), suspend_stats success ${ok0} -> ${ok1}"
        tail -n 30 "${W}/${cyc}.log"
        report_fail "${cyc}"
    fi

    # The RTC alarm woke the system: it has fired, and the system was away
    # for at least the alarm time.
    if [ -n "${alarm}" ]; then
        warn_msg "${cyc}: the RTC alarm (${alarm}) is still pending: woken by something else"
        report_fail "${cyc}-rtc-wake"
    elif [ $((t1 - t0)) -lt $(((SLEEP - 1) * 100)) ]; then
        warn_msg "${cyc}: back after $(((t1 - t0) / 100)) s, before the ${SLEEP} s alarm"
        report_fail "${cyc}-rtc-wake"
    else
        report_pass "${cyc}-rtc-wake"
    fi

    # Entry: suspend entry to the last step before sleeping; resume: the
    # first step after waking to suspend exit.
    te="$(log_time "PM: suspend entry" "${W}/${cyc}.log")"
    ts="$(log_time "PM: suspend-to-idle|Disabling non-boot CPUs" "${W}/${cyc}.log")"
    tw="$(log_time "PM: resume from suspend-to-idle|Enabling non-boot CPUs" "${W}/${cyc}.log")"
    tx="$(log_time "PM: suspend exit" "${W}/${cyc}.log")"
    [ -n "${te}" ] && [ -n "${ts}" ] && add_metric "${cyc}-entry-time" pass \
        "$(awk -v a="${te}" -v b="${ts}" 'BEGIN { printf "%.3f", (b - a) * 1000 }')" ms
    if [ -n "${tw}" ] && [ -n "${tx}" ]; then
        add_metric "${cyc}-resume-time" pass \
            "$(awk -v a="${tw}" -v b="${tx}" 'BEGIN { printf "%.3f", (b - a) * 1000 }')" ms
    fi

    missing="$(awk 'NR == FNR { a[$0] = 1; next } !($0 in a)' "${W}/dev.1" "${W}/dev.0")"
    crashed="$(grep -E "${RPROC_CRASH}" "${W}/${cyc}.log")"
    if [ -z "${missing}" ] && [ -z "${crashed}" ]; then
        report_pass "${cyc}-devices-back"
    else
        [ -z "${missing}" ] || { warn_msg "${cyc}: missing after resume:"; echo "${missing}"; }
        [ -z "${crashed}" ] || { warn_msg "${cyc}: remoteproc crash:"; echo "${crashed}"; }
        report_fail "${cyc}-devices-back"
    fi

    bad="$(grep -E "${KERNEL_BAD}" "${W}/${cyc}.log")"
    if [ -z "${bad}" ]; then
        report_pass "${cyc}-kernel-clean"
    else
        warn_msg "${cyc}: kernel log of the cycle:"
        cat "${W}/${cyc}.log"
        report_fail "${cyc}-kernel-clean"
    fi

    # s2idle: every CPU stayed in its deepest enabled idle state for at
    # least half of the suspend, at least 1 ms per entry on average
    # (cpuidle s2idle time and usage: a platform that refuses the state
    # makes the s2idle loop retry it, tens of microseconds per refused
    # entry, which still adds up to most of the suspend), and the PSCI
    # domain states their s2idle counters show.
    [ "$1" = s2idle ] || [ "${STATE}" = freeze ] || return 0
    awk -v us="$(((t1 - t0) * 10000 + 1))" 'NR == FNR { if ($9 != "-") { u[$1 " " $2] = $8; t[$1 " " $2] = $9 }; next }
        ($1 " " $2) in u && $7 == 0 { d[$1] = $3; v[$1] = $8 - u[$1 " " $2]; r[$1] = $9 - t[$1 " " $2] }
        END { for (c in d) printf "%s %s %d %d %.0f %.0f\n", c, d[c], v[c], r[c], r[c] * 100 / us, (v[c] > 0 ? r[c] / v[c] : 0) }' \
        "${W}/s2.0" "${W}/s2.1" | sort > "${W}/s2.delta"
    if [ ! -s "${W}/s2.delta" ]; then
        info_msg "${cyc}: no s2idle idle state counters"
        report_skip "${cyc}-s2idle-deepest"
    else
        info_msg "${cyc}: deepest state per CPU (cpu state s2idle-entries s2idle-time-us % of the suspend us-per-entry):"
        cat "${W}/s2.delta"
        add_metric "${cyc}-s2idle-residency-min" pass \
            "$(awk 'NR == 1 || $5 < m { m = $5 } END { print m }' "${W}/s2.delta")" "%"
        add_metric "${cyc}-s2idle-us-per-entry-min" pass \
            "$(awk 'NR == 1 || $6 < m { m = $6 } END { print m }' "${W}/s2.delta")" us
        if awk '$5 < 50 || $6 < 1000 { bad = 1 } END { exit bad }' "${W}/s2.delta"; then
            report_pass "${cyc}-s2idle-deepest"
        else
            warn_msg "${cyc}: CPUs that did not stay in their deepest state (under half of the suspend, or under 1 ms per entry: refused and retried):"
            awk '$5 < 50 || $6 < 1000 { print $1, $2, $3 " entries", $6 " us per entry" }' "${W}/s2.delta"
            report_fail "${cyc}-s2idle-deepest"
        fi
    fi
    if [ -n "${DOMAINS}" ]; then
        awk 'NR == FNR { if ($6 != "-") u[$1 " " $2] = $6; next }
            ($1 " " $2) in u { printf "%s %s %d\n", $1, $2, $6 - u[$1 " " $2] }' \
            "${W}/gs2.0" "${W}/gs2.1" | while read -r dom st n; do
            add_metric "${cyc}-genpd-$(slug "${dom}")-$(slug "${st}")-s2idle" pass "${n}" entries
        done
    fi
}

STATE=""
if ! phase suspend; then
    :
elif ! grep -qw -e mem -e freeze "${SYS_POWER}"/state 2>/dev/null; then
    skip_suspend "no system sleep state in ${SYS_POWER}/state ($(cat "${SYS_POWER}"/state 2>/dev/null))"
else
    RTC=""
    for r in "${RTC_CLASS}"/rtc*; do
        [ -e "${r}/wakealarm" ] || continue
        [ "$(cat "${r}/device/power/wakeup" 2>/dev/null)" = disabled ] && continue
        RTC="${r}"
        break
    done
    info_msg "${SYS_POWER}/state: $(cat "${SYS_POWER}"/state); mem_sleep: $(cat "${SYS_POWER}"/mem_sleep 2>/dev/null)"
    if [ -z "${RTC}" ]; then
        skip_suspend "no RTC with a wake alarm ($(echo "${RTC_CLASS}"/*))"
    else
        info_msg "wake source: ${RTC} ($(cat "${RTC}/name" 2>/dev/null))"
        report_pass "suspend-supported"
        # Device suspend and resume timings in the kernel log, if the
        # kernel offers them.
        dbg=""
        [ -w "${SYS_POWER}"/pm_debug_messages ] && dbg="$(cat "${SYS_POWER}"/pm_debug_messages)" &&
            echo 1 > "${SYS_POWER}"/pm_debug_messages
        modes="${MODES}"
        [ -n "${modes}" ] || modes="$(sed -n 's/.*\[\([a-z0-9]*\)\].*/\1/p' "${SYS_POWER}"/mem_sleep 2>/dev/null)"
        [ -n "${modes}" ] || modes=freeze
        for m in ${modes}; do
            if [ "${m}" = freeze ]; then
                STATE=freeze
            elif grep -qw "${m}" "${SYS_POWER}"/mem_sleep 2>/dev/null &&
                echo "${m}" > "${SYS_POWER}"/mem_sleep; then
                STATE=mem
            else
                info_msg "mem_sleep has no ${m}: $(cat "${SYS_POWER}"/mem_sleep 2>/dev/null)"
                report_skip "suspend-${m}"
                continue
            fi
            i=1
            while [ "${i}" -le "${CYCLES}" ]; do
                run_cycle "${m}" "${i}"
                i=$((i + 1))
            done
        done
        [ -n "${dbg}" ] && echo "${dbg}" > "${SYS_POWER}"/pm_debug_messages
    fi
fi
exit 0
