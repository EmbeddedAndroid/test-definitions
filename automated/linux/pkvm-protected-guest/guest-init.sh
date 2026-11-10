#!/bin/busybox sh
# shellcheck shell=dash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Qualcomm Technologies, Inc. and/or its subsidiaries.
#
# /init of the pkvm-protected-guest initramfs (static busybox): report
# readiness on the virtio console and hand it to a shell. NONCE comes from
# pvmtest.nonce= on the kernel command line.
/bin/busybox --install -s /bin
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mount -t tmpfs tmpfs /tmp
NONCE="$(sed -n 's/.*pvmtest\.nonce=\([0-9]*\).*/\1/p' /proc/cmdline)"
export NONCE
echo "kvm-guest: ready vcpus=$(grep -c ^processor /proc/cpuinfo) release=$(uname -r) rdma=$(dmesg | grep -c 'created restricted DMA pool') uptime=$(cut -d ' ' -f 1 /proc/uptime)"
exec setsid cttyhack sh
