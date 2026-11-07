# Xen tests

Tests for a board that boots Xen at EL2 with Linux as the control domain
(dom0). They are generic: nothing in them is specific to a SoC, and every
board fact is a parameter. Each definition first checks that Linux runs on
Xen as dom0; without Xen every case reports `skip` with the reason, so the
same plan runs on a board's Xen and non-Xen boots and only the Xen boots
report results.

## Definitions

| Definition | Cases | What it checks |
|---|---|---|
| `xen-detect` | `xen-hypervisor`, `xen-dom0`, `xen-version`, `xen-capabilities`, `xen-fingerprint` | `/sys/hypervisor/type` is `xen`; `/proc/xen/capabilities` (xenfs, mounted if needed) has `control_d`; the Xen version is readable and matches `VERSION` when given; the guest ABI capabilities are listed and include `CAPS` when given; the `Xen version` banner in the Xen console ring (`xl dmesg`) carries `FINGERPRINT` when given (otherwise skipped). Without Xen all cases skip; `REQUIRE_XEN=true` fails them instead. A devicetree with a Xen `hypervisor` node and a kernel that does not report Xen fails. |
| `xen-dom0` | `dom0-vcpus`, `grant-table`, `hvc0-console`, `event-channels`, `dom0-log-xen-clean`, `xen-log-clean` | dom0 has one vCPU per host CPU (`xl info` `nr_cpus`, or `DOM0_VCPUS`); the grant table is set up (`Grant tables using version N layout`); `/dev/hvc0` is a console; event channels use the FIFO or 2-level ABI and the upcall interrupt is registered; no error from the Linux Xen drivers and no WARNING or BUG trace through Xen code in the kernel log; no assertion, `Xen BUG`, `Xen WARN`, call trace or panic in the Xen console ring. `IGNORE` (extended regex) drops known lines from both log checks. |
| `xen-xl` | `xl-present`, `xenstored`, `xen-init-dom0`, `xenconsoled`, `xl-info`, `xl-list-dom0`, `xl-dmesg`, `guest-1vcpu-boot`, `guest-1vcpu-vcpus`, `guest-1vcpu-shutdown`, `parallel-N-boot`, `parallel-N-running`, `parallel-N-shutdown`, `destroy`, `destroy-memory-returned` | The toolstack starts (xenstored, xen-init-dom0 once per boot, xenconsoled logging every guest console) and `xl info`, `xl list` (Domain-0) and `xl dmesg` answer. A 1-vCPU guest boots (ready line), sees one vCPU, and on `xl shutdown` prints its poweroff line and is gone. `PARALLEL` guests with `VCPUS` vCPUs are created back to back: each must print its ready line, each must then still be a domain in `xl list`, and each must shut down cleanly on `xl shutdown`. A running guest removed with `xl destroy` is gone (no dying domain left) and `xl info` `free_memory` is back to at least its value before the guest, taken once free memory has settled (Xen returns a dead domain's memory some time after the domain is gone). A board without `xl` fails `xl-present` and skips the rest. |
| `xen-tee-smc` | `xen-mediator`, `dom0-optee-bound`, `dom0-tee-devices`, `dom0-xtest`, `guest-tee-reachable`, `guest-tee-denied`, `guest-teardown` | OP-TEE through Xen's OP-TEE mediator (OP-TEE SMC ABI, Xen `CONFIG_OPTEE`): Xen logged `Using TEE mediator for OP-TEE`; dom0's OP-TEE driver bound over SMC (not FF-A) with `/dev/tee0` and `/dev/teepriv0`; `xtest XTEST` passes in dom0 when `XTEST` is given; a guest created with `tee = "optee"` reaches OP-TEE; a guest without `tee` does not; `xl destroy` of the OP-TEE guest leaves no dying domain. |
| `xen-tee-ffa` | `xen-mediator`, `xen-spmc-version`, `dom0-ffa-driver`, `dom0-optee-bound`, `dom0-tee-devices`, `dom0-xtest`, `guest-tee-reachable`, `guest-tee-denied`, `guest-teardown` | OP-TEE through Xen's FF-A mediator (Xen `CONFIG_FFA`, OP-TEE as an FF-A partition such as the S-EL1 SPMC): Xen logged `Using TEE mediator for FF-A` and the SPMC's FF-A version; dom0's FF-A driver found the firmware and the OP-TEE driver is bound to an FF-A device; the same dom0 and guest checks as `xen-tee-smc` with `tee = "ffa"`; the teardown also fails when Xen logged a shared memory handle it failed to reclaim (`ffa: Failed to reclaim`), which happens when the SPMC does not handle VM created and destroyed messages (OP-TEE without `CFG_NS_VIRTUALIZATION`). |

`xen-tee-smc` and `xen-tee-ffa` are skipped when Xen uses another TEE
mediator or none (`REQUIRE=true` fails them instead). If the Xen console
ring has wrapped and lost the mediator line, dom0's OP-TEE driver bound
over the matching transport is taken as the evidence instead. The whole
OP-TEE regression suite is the `optee-xtest` definition; `XTEST` here is
meant for a short smoke run.

Guest states are read from each guest's console, never inferred from
timing: a guest that powers off before a fixed sleep, or a console line
not yet logged when the domain disappears, cannot make a case pass or fail
by accident.

## Enabling the block in the plan

`plans/open-boot-stack/open-boot-stack.yaml` lists the five definitions in
its `optional:` section as block `xen`, variable `XEN`, default `false`,
run right before `kernel-health` (so that `kernel-health` sees any warning
a guest left in dom0). A job generator that does not know about optional
blocks, or leaves `XEN` false, produces exactly the plan without them. A
generator that sets `XEN` to true inserts them; all their cases skip on a
boot without Xen, so the block can stay on for every job of a Xen board.

## Guest image and console protocol

The guest cases need a guest kernel and initramfs (`KERNEL`, `INITRD`;
default `/opt/xen-guest/Image` and `/opt/xen-guest/initramfs.cpio.gz`,
which qcom-buildroot's `xen_guest_ext` installs with `XEN=y`). The tests
write each guest's xl configuration themselves:

```
name = "<name>"
kernel = "<KERNEL>"
ramdisk = "<INITRD>"
extra = "console=hvc0 xenguest=<name>"
memory = <MEMORY>
vcpus = <n>
tee = "optee" | "ffa"          # TEE cases only
on_poweroff = "destroy"
on_reboot = "destroy"
on_crash = "destroy"
```

The guest's init must print on hvc0, with `<name>` taken from
`xenguest=` on its command line:

```
xen-guest: ready name=<name> vcpus=<online CPUs> ...
xen-guest: tee name=<name> ffa=<0|1> optee=<0|1> tee0=<0|1>
```

then stay up. `ffa` is 1 when the kernel's FF-A driver found the
firmware, `optee` when the OP-TEE driver initialized, `tee0` when
`/dev/tee0` exists. When the toolstack asks the guest to shut down, the
kernel runs `/sbin/poweroff`, which must print

```
xen-guest: poweroff name=<name>
```

and then power off. The guest kernel needs Xen guest support with the hvc
console (`CONFIG_XEN`, `CONFIG_HVC_XEN`) and, for the TEE cases, the FF-A
transport and the OP-TEE driver (`CONFIG_ARM_FFA_TRANSPORT`, `CONFIG_TEE`,
`CONFIG_OPTEE`).

## What a new Xen port needs

- dom0 kernel: `CONFIG_XEN`, `CONFIG_XENFS`, `CONFIG_XEN_DEV_EVTCHN`,
  `CONFIG_XEN_GNTDEV`, `CONFIG_XEN_BACKEND`, `CONFIG_HVC_XEN`; for the TEE
  cases the OP-TEE driver and, with FF-A, `CONFIG_ARM_FFA_TRANSPORT`.
- dom0 rootfs: the Xen toolstack built from the same Xen tree as the
  hypervisor (xl, xenstored, xenconsoled, xen-init-dom0; Xen does not keep
  its domctl and sysctl interfaces stable across versions), and the guest
  image above. qcom-buildroot's `XEN=y` adds both.
- Xen: enough free memory beyond dom0 for `PARALLEL` guests of `MEMORY`
  MiB plus one; for the TEE cases Xen built with the mediator
  (`CONFIG_OPTEE` or `CONFIG_FFA`) and, for FF-A guests to be torn down
  cleanly, an SPMC that handles VM created and destroyed messages.
- The board's facts in the job: `FINGERPRINT` (the string the board's
  Xen build carries in its version banner), `DOM0_VCPUS` when Xen limits
  dom0's vCPUs, and `IGNORE` for known, explained log lines.

## Parameters used on the Nord Ride Embedded (SA8797P)

| Definition | Parameters |
|---|---|
| `xen-detect` | `FINGERPRINT=<NXENFP of the Xen build> CAPS=xen-3.0-aarch64` |
| `xen-xl` | `PARALLEL=4 VCPUS=2 MEMORY=256` |
| `xen-tee-ffa`, `xen-tee-smc` | `XTEST="1001 1004"` |
