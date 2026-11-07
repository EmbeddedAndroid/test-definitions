#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Qualcomm Technologies, Inc. and/or its subsidiaries.
#
# Helpers shared by the Xen test definitions (sourced after sh-test-lib).
# Every definition of this directory first calls xen_require: without Xen
# (or not in the control domain) all its cases are skipped with the reason,
# so the definitions can run in every job of a plan.

XEN_PATH_EXTRA="/usr/sbin:/usr/lib/xen/bin:/usr/local/sbin"
# Where Linux shows Xen (overridden by the definitions' own tests).
XEN_SYS="${XEN_SYS:-/sys/hypervisor}"
XEN_PROC="${XEN_PROC:-/proc/xen}"
PATH="${PATH}:${XEN_PATH_EXTRA}"
export PATH

# xen_running: 0 when Linux runs on Xen. The devicetree hypervisor node
# says so even when the kernel was built without Xen support, which then
# fails xen_require instead of skipping.
xen_running() {
    [ "$(cat "${XEN_SYS}/type" 2> /dev/null)" = "xen" ] && return 0
    grep -q 'xen,xen' /proc/device-tree/hypervisor/compatible 2> /dev/null
}

xen_mount_xenfs() {
    [ -d "${XEN_PROC}" ] || return 1
    [ -e "${XEN_PROC}/capabilities" ] && return 0
    mount -t xenfs xenfs "${XEN_PROC}" 2> /dev/null
}

xen_is_dom0() {
    xen_mount_xenfs
    grep -q control_d "${XEN_PROC}/capabilities" 2> /dev/null
}

# xen_skip_cases <reason> <case>...: skip every case and exit.
xen_skip_cases() {
    reason="$1"
    shift
    warn_msg "${reason}"
    echo "SKIP REASON: ${reason}"
    for c in "$@"; do
        report_skip "${c}"
    done
    exit 0
}

# xen_require <require> <case>...: skip all cases unless this is dom0 on
# Xen. With <require> = true, a Linux without Xen fails the cases instead
# (a job that booted Xen and expects it).
xen_require() {
    req="$1"
    shift
    if ! xen_running; then
        if [ "${req}" = "true" ]; then
            warn_msg "not running on Xen, which this job requires"
            for c in "$@"; do
                report_fail "${c}"
            done
            exit 0
        fi
        xen_skip_cases "not running on Xen" "$@"
    fi
    if [ "$(cat "${XEN_SYS}/type" 2> /dev/null)" != "xen" ]; then
        warn_msg "the devicetree has a Xen node but /sys/hypervisor/type is not xen: kernel without CONFIG_XEN?"
        for c in "$@"; do
            report_fail "${c}"
        done
        exit 0
    fi
    xen_is_dom0 || xen_skip_cases "not the Xen control domain (no control_d in /proc/xen/capabilities)" "$@"
}

# proc_running <comm>: a process with that name exists (BusyBox images may
# have no pgrep).
proc_running() {
    for c in /proc/[0-9]*/comm; do
        [ "$(cat "${c}" 2> /dev/null)" = "$1" ] && return 0
    done
    return 1
}

proc_kill() {
    for d in /proc/[0-9]*; do
        [ "$(cat "${d}/comm" 2> /dev/null)" = "$1" ] && kill "${d#/proc/}" 2> /dev/null
    done
    i=0
    while proc_running "$1" && [ "${i}" -lt 10 ]; do
        sleep 1
        i=$((i + 1))
    done
}

# xen_toolstack <log dir>: xenstored, xen-init-dom0 and xenconsoled
# logging every guest console to <log dir>/guest-<name>.log. A running
# xenconsoled is restarted, since it may not be logging guest consoles.
# Returns 1 with the failing step in XEN_TOOLSTACK_ERROR.
# shellcheck disable=SC2034
xen_toolstack() {
    logdir="$1"
    XEN_TOOLSTACK_ERROR=""
    mkdir -p /var/run/xen /var/run/xenstored /var/lib/xen /var/lib/xenstored \
        /var/log/xen /var/xen/dump "${logdir}"
    if ! proc_running xenstored; then
        xenstored --pid-file /var/run/xenstored.pid > "${logdir}/xenstored.log" 2>&1
        i=0
        while [ ! -S /var/run/xenstored/socket ] && ! proc_running xenstored && [ "${i}" -lt 10 ]; do
            sleep 1
            i=$((i + 1))
        done
    fi
    if ! proc_running xenstored; then
        XEN_TOOLSTACK_ERROR="xenstored"
        return 1
    fi
    # xen-init-dom0 runs once per boot; a second run is not idempotent on
    # every Xen version.
    if [ ! -e /var/run/xen/xen-init-dom0.done ]; then
        if ! xen-init-dom0 > "${logdir}/xen-init-dom0.log" 2>&1; then
            XEN_TOOLSTACK_ERROR="xen-init-dom0"
            return 1
        fi
        touch /var/run/xen/xen-init-dom0.done
    fi
    proc_kill xenconsoled
    xenconsoled --log=guest --log-dir="${logdir}" --pid-file=/var/run/xenconsoled.pid
    i=0
    while ! proc_running xenconsoled && [ "${i}" -lt 10 ]; do
        sleep 1
        i=$((i + 1))
    done
    if ! proc_running xenconsoled; then
        XEN_TOOLSTACK_ERROR="xenconsoled"
        return 1
    fi
    return 0
}

# xen_guest_cfg <file> <name> <kernel> <initrd> <memory MiB> <vcpus> [tee]
xen_guest_cfg() {
    {
        echo "name = \"$2\""
        echo "kernel = \"$3\""
        echo "ramdisk = \"$4\""
        echo "extra = \"console=hvc0 xenguest=$2\""
        echo "memory = $5"
        echo "vcpus = $6"
        [ -z "$7" ] || echo "tee = \"$7\""
        echo 'on_poweroff = "destroy"'
        echo 'on_reboot = "destroy"'
        echo 'on_crash = "destroy"'
    } > "$1"
}

# Guest console protocol (see README.md): the guest's init prints
#   xen-guest: ready name=<name> vcpus=<n> ...
#   xen-guest: tee name=<name> ffa=<0|1> optee=<0|1> tee0=<0|1>
# and, when asked to shut down, before powering off
#   xen-guest: poweroff name=<name>
guest_log() {
    tr -d '\r' < "${XEN_LOGDIR}/guest-$1.log" 2> /dev/null
}

# guest_wait <name> <pattern> <seconds>: until the guest console shows the
# pattern (0) or the time is up (1).
guest_wait() {
    i=0
    while ! guest_log "$1" | grep -q "$2"; do
        [ "${i}" -ge "$3" ] && return 1
        sleep 1
        i=$((i + 1))
    done
    return 0
}

# guest_gone <name> <seconds>: the domain no longer exists, and no dying
# domain is left (xl list shows a dying domain as "(null)" in state d).
guest_gone() {
    i=0
    while xl domid "$1" > /dev/null 2>&1 || xl list 2> /dev/null | grep -q -E '^\(null\) .* [-a-z]*d[-a-z]* '; do
        [ "${i}" -ge "$2" ] && return 1
        sleep 1
        i=$((i + 1))
    done
    return 0
}

# xen_free_memory: free memory in MiB as xl info reports it.
xen_free_memory() {
    xl info 2> /dev/null | sed -n 's/^free_memory *: *//p'
}

# xen_free_memory_settled <seconds>: free memory once it has not changed
# for 3 s (Xen returns a dead domain's memory some time after the domain is
# gone), or the last value after <seconds>.
xen_free_memory_settled() {
    i=0
    same=0
    last="$(xen_free_memory)"
    while [ "${same}" -lt 3 ] && [ "${i}" -lt "$1" ]; do
        sleep 1
        i=$((i + 1))
        cur="$(xen_free_memory)"
        if [ "${cur}" = "${last}" ]; then
            same=$((same + 1))
        else
            same=0
        fi
        last="${cur}"
    done
    echo "${last}"
}

# guest_check_image <kernel> <initrd> <case>...: skip the cases without
# the guest image.
guest_check_image() {
    k="$1"
    r="$2"
    shift 2
    [ -f "${k}" ] || xen_skip_cases "no guest kernel ${k}" "$@"
    [ -f "${r}" ] || xen_skip_cases "no guest initramfs ${r}" "$@"
}
