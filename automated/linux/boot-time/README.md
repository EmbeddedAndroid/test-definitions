# boot-time

Reports how long the board took to boot, measured on the target after
login, as LAVA measurements in seconds:

| Case | What it measures |
|---|---|
| `pre-kernel` | From the Arm generic timer's zero to the kernel's time zero: `CNTVCT_EL0 / CNTFRQ_EL0` minus the time stamp of the kernel log line in which `cntvct-arm64` writes that reading (through `/dev/kmsg`, so the test needs root). |
| `kernel-to-init` | The kernel log time of `Run <init> as init process`. |
| `kernel-to-login` | The start time of the process init started for the test's session: the getty that printed the login prompt, and then became (or started) login and the shell. Process start times count on `CLOCK_BOOTTIME`, so the `CLOCK_BOOTTIME` that `cntvct-arm64` logs with its reading moves it to the kernel log clock. |

The kernel's time zero is the zero of its log time stamps, set when
`time_init()` registers the Arm generic timer as the scheduler clock.
Everything before it counts as `pre-kernel`: the firmware, an EFI stub,
and the kernel's own early setup (`setup_arch()`, memory and scheduler
setup, and the early console printing their messages, whose log lines
read 0.000000). On a board with an early console at 115200 baud that
was about 1 s. The three values share that zero, so `pre-kernel` plus
`kernel-to-login` is the time from the counter's zero to the login
prompt. `CLOCK_BOOTTIME` is not used as the zero: it runs on jiffies
until `clocksource_done_booting()` and falls behind the log clock by the
ticks lost until then (about 0.13 s on that board).

## Assumption: the counter starts at reset

`pre-kernel` is the time spent before the kernel only where the system
counter starts at zero on reset and runs on, which the Arm architecture
expects but does not require. It degrades as follows:

- Firmware that starts the counter late, or sets it to some value, makes
  the result short or long by that amount; the test cannot tell.
- A warm reset that does not reset the counter adds the time of the
  previous boot. Run the test after a cold boot.
- The kernel log clock stops in system suspend while the counter runs on,
  so a suspend before the test adds its length to `pre-kernel` (and
  takes it from `kernel-to-login`). Run the test before any suspend.
- A counter that was reset after the kernel started, or started after it,
  reads less than the kernel clock: `skip`.
- A hypervisor can offset the virtual counter (`CNTVOFF_EL2`), which is
  not visible from Linux. Linux clears the offset when it starts at EL2,
  so the result counts only when the kernel log shows `CPU: All CPU(s)
  started at EL2`; otherwise (a kernel at EL1, or the line pushed out of
  the log) `skip`. A KVM guest with nested virtualization starts at a
  virtual EL2, so `smccc: KVM: hypervisor services detected` in the log
  is a `skip` too. A guest at a virtual EL2 under another hypervisor, or
  under QEMU's emulation, cannot be told apart and is measured from its
  virtual counter's zero.
- `CNTFRQ_EL0` of 0 (frequency not set), or not the rate in the kernel's
  `arch_timer: cp15 timer running at` line (`cp15 timer(s)` or `cp15
  and mmio timer(s)` before Linux 6.18; a devicetree `clock-frequency`
  that works around a wrong `CNTFRQ_EL0` changes that rate), or a
  counter that cannot be read: `skip`.

`kernel-to-init` needs `CONFIG_PRINTK_TIME` and the line still in the
kernel log; `kernel-to-login` counts from the getty only for a console or
serial login, and a getty respawned after a failed login starts later.
Each is `skip` when it cannot be read; `pre-kernel` and `kernel-to-login`
also need the reading `cntvct-arm64` writes to the kernel log.

`cntvct-arm64` is built from `cntvct.c` by `make` (see the Makefile:
NOLIBC= the tools/include/nolibc directory of a Linux tree, UAPI= arm64
kernel UAPI headers). `boot-time.sh -t <binary>` runs another one.
