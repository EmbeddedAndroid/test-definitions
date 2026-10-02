# Open boot stack test plan

Bring-up checks for an open boot stack (TF-A BL2 or U-Boot SPL, BL31,
OP-TEE, U-Boot, Linux) on an Arm64 SoC. The test definitions are generic:
everything platform specific is a parameter, and a check whose parameter
is empty, or whose hardware or tool is missing, reports `skip` rather than
`fail`.

## Test definitions

| Definition | What it checks |
|---|---|
| `boot-fingerprint` | The build fingerprint in `/proc/version`, the rootfs (`/etc/issue`) and, where the firmware publishes it, the SMBIOS BIOS version (U-Boot). |
| `boot-handoff` | Boot CPU (MPIDR), CPUs online, all CPUs started at EL2, KVM mode and `/dev/kvm`, the OP-TEE driver and `/dev/tee0`, PSCI CPU PM domains in OSI or PC mode. |
| `cpufreq-policy` | Every policy set to its lowest and highest frequency with the userspace governor: the frequency read back where the driver reports the running frequency, and a busy loop timed at both frequencies on one CPU of the policy, whose runtime ratio must match the frequency ratio. Then a stress-ng load on all online CPUs: the load completes and every policy scales up. |
| `maxcpus` | With `maxcpus=N`: N CPUs online at boot, then every other CPU brought online (PSCI CPU_ON of a CPU the firmware has not started). |
| `memtest` | With `memtest=N` and `CONFIG_MEMTEST`: the kernel's early memory test ran N patterns over all free memory and reported no bad memory. |
| `remoteproc-smoke` | The DSP remoteprocs are running and none has crashed since boot (a remoteproc that crashed and was recovered is running again). |
| `fastrpc` | FastRPC round trips to each DSP (signed and unsigned PD) and the FastRPC nodes of DSPs fastrpc_test cannot call. |
| `inference` | Image classification (MobileNetV2, seven images) on every processing unit (PU) of the board with the same model and inputs: on each PU every image's top-1 is its expected class, and the latency per inference (mean, p50, p90 over the timed runs after warm-up) is reported as measurements in ms. Each NPU (one per Hexagon NSP, QNN HTP backend over FastRPC) also agrees with the QNN CPU backend (same top-1, logit cosine at least `MIN_COSINE`) and with the SDK's x86 HTP simulation (within `MAX_HOST_DIFF`), and is faster than it. A PU the board does not have is one `skip` case with the reason. The log ends with a table comparing the PUs. |
| `alsa-dsp-restart` | Playback, a DSP restart while idle and one in the middle of a stream: the DSP and the card come back, the stream ends instead of hanging, playback works again. |
| `remoteproc-restart` | Each remoteproc stopped and started through sysfs, three times: offline after the stop, running after the start, its rpmsg channels back with the same drivers, no remoteproc crash, warning or oops in the kernel log. Remoteprocs known not to survive a restart are listed with a reason and reported as skip. |
| `optee-xtest` | The OP-TEE regression suite. |
| `gpu-render` | A DRM render node and a headless render with pixel readback (`egl-readback`). |
| `video-codec` | V4L2 stateful codec through FFmpeg's v4l2m2m wrappers: hardware decodes of H.264, HEVC and VP9 reference streams match the software decode frame by frame (MD5), a hardware encode decodes to the right frame count with a minimum PSNR; decodes after runtime suspend and after a driver rebind; without its firmware file the driver must not probe, or must not decode if it loads the firmware on the first open. Needs FFmpeg 7.0 or later and the streams in `/usr/share/video-codec` (qcom-buildroot `qcom/video`). |
| `kvm-unit-tests` | The [KVM unit tests](https://gitlab.com/kvm-unit-tests/kvm-unit-tests) against `/dev/kvm`: small guests that each check part of KVM and its virtual hardware (vectors, SMP, GIC and ITS, timers, PSCI, PMU, debug, FPU context, micro benchmarks). Runs a prebuilt copy in `/opt/kvm-unit-tests` (built for kvmtool on the boards below), one case per test. |
| `kvm-guest` | A Linux guest under KVM with kvmtool (2 vCPUs, virtio console): it reaches userspace with the vCPUs asked for, runs a command sent over its console and powers off, so that kvmtool exits 0; the time to its ready line is a measurement. |
| `kernel-health` | Kernel warnings, BUGs, oopses, call traces and panics since boot. |
| `systemready-acs` | The results of an Arm SystemReady devicetree band ACS run, read from Arm's parsed results on the ACS results partition: one case per SCT test, BSA or PFDI rule, FWTS test, DT check and ACS Linux tool check, and Arm's compliance verdict per suite (see below). |

## Console checks in the LAVA job

The firmware stages print their fingerprint on the console only, and a
reboot or a poweroff ends the test shell, so the job does these itself:

- After the flash, a `minimal` boot without prompts powers the board on and
  a `monitors` test matches every firmware banner up to the first kernel
  line. The pattern captures the stage name as the test case and the
  fingerprint as the result, `fixupdict` maps the expected fingerprint to
  `pass` and `expected` lists the stages, so a stage that is missing or
  carries another fingerprint fails:

  ```yaml
  - test:
      monitors:
      - name: firmware-fingerprint-cold
        start: SBL1, End
        end: Booting Linux on physical CPU
        pattern: (?P<test_case_id>OP-TEE version|U-Boot SPL|U-Boot|BL31|BL2)[^\r\n]*?(?P<result>MONZAFP-261001-153751)
        fixupdict:
          MONZAFP-261001-153751: pass
        expected: [bl2, bl31, op_tee_version, u_boot]
  ```

  `start` must be a line the platform's ROM or first stage loader prints
  on a real boot only (not while it sits in its flashing mode).
- A second `minimal` boot with `reset: false` logs in.
- The warm reboot is an `interactive` test that sends `reboot` and waits for
  `reboot: Restarting system`, followed by the same monitor, a login and
  `boot-fingerprint`, `boot-handoff` and `kernel-health` again. The
  poweroff is an `interactive` test that sends `poweroff` and waits for
  `reboot: Power down`.

The `maxcpus=N` cases are separate jobs, one per N, booting a kernel image
whose command line carries `maxcpus=N`: the console monitor,
`boot-fingerprint`, `boot-handoff` (`CPUS=N`), `maxcpus`, `cpufreq-policy`
(`ONLINE_ALL=true`) and `kernel-health`.

The memory test is a separate job booting a kernel image whose command
line carries `memtest=N`: the console monitor, `memtest` first (its lines
are among the first in the kernel log, which later messages can push
out), then `boot-fingerprint`, `boot-handoff` and `kernel-health`.

The KVM tests run in the full job, after `gpu-render` and before
`kernel-health`, so a KVM warning shows up there too.

`remoteproc-restart` runs in the full job after the DSP and audio tests,
so that they see the remoteprocs as booted, and before `kernel-health`,
which counts any warning a restart leaves behind.

The negative control is the `maxcpus=2` job on an image booted with
`maxcpus=2 kvm-arm.mode=none`, expecting a wrong fingerprint, a wrong
`maxcpus` value and KVM: every console stage, `boot-fingerprint`,
`maxcpus-cmdline`, `maxcpus-online-at-boot`, `kvm-initialized`,
`kvm-device` (`boot-handoff` and `kvm-unit-tests` with
`REQUIRE_KVM=true`) and all `kvm-guest` cases must fail, and no KVM unit
test may pass (the runner skips them all without `/dev/kvm`).

`inference` runs after `fastrpc` in the full job. `PUS` names what the
board has, one entry per PU and runtime (`cpu:qnn`,
`npu<N>:qnn-htp:<Hexagon arch>:<QNN device id>:<remoteproc>` per NSP,
`cpu:tflite` and `gpu:tflite-gpu`); `ABSENT` names what it does not have,
with the reason. The TensorFlow Lite entries run the image's `tflite-run`
on a TensorFlow Lite build of the same model: XNNPACK on the CPU, checked
against the x86 LiteRT outputs, and the GPU delegate (OpenCL, fp16),
checked against the CPU run as the NPU is against the QNN CPU backend, as
the stock VENTUNO Q and UNO Q images run models on the GPU. The Qualcomm AI
Runtime (QAIRT) is not in the image, since its license does not allow
redistributing the SDK on its own: the job writes the SDK zip to the
overlay partition as a `file` overlay, which the LAVA dispatcher downloads
from Qualcomm's public URL for each job (it is never uploaded anywhere).
The test checks the zip's SHA-256 and extracts only the files it runs
(`qnn-net-run`, `qnn-profile-viewer`, the CPU and HTP backends, the HTP
stub of the board's architecture and its Hexagon skel). The model comes
with the image (qcom-buildroot builds it from pinned public inputs) and
holds open content only: MobileNetV2 from the ONNX model zoo (Apache-2.0)
as two DLCs (fp32 for the CPU backend, 8-bit with per-channel weights for
the HTP), seven public domain or CC0 images preprocessed to the model
input, the expected classes, and the x86 outputs of both backends. The
FastRPC userspace and the DSP runtime come with the image too. Latency
comes from `qnn-net-run`'s basic profile (one EXECUTE time per
inference); performance has no pass threshold beyond the NPU being faster
than the CPU, so builds are compared by differencing the measurements of
two runs. The negative control job also runs `inference` with
`NEGATIVE=htp-down` (the NSP remoteprocs stopped: every NPU case must
fail, the CPU cases pass), on boards with a GPU entry with
`NEGATIVE=gpu-down` (no OpenCL platform visible: every GPU case must fail)
and with `NEGATIVE=wrong-class` (the expected classes rotated: every top-1
case must fail). Without the zip, the model or `tflite-run`, the cases of
the PUs that need them are skipped.

`kvm-guest` needs `socat` besides kvmtool: kvmtool reads console input only
from a terminal, so the test runs it on a pty that `socat` connects to the
test.

## Parameters used on the Arduino VENTUNO Q (QCS8275)

| Definition | Parameters |
|---|---|
| `boot-handoff` | `BOOT_CPU=0x10000 CPUS=8 EXCEPTION_LEVEL=EL2 KVM=vhe TEE=optee PSCI_MODE=osi` |
| `remoteproc-smoke` | `DEVICE="adsp cdsp gpdsp0" WAIT_TIME=30` |
| `fastrpc` | `TESTS="adsp:adsp:0:0 cdsp:cdsp:3:0 cdsp-unsigned-pd:cdsp:3:1" NODES="gpdsp0:/dev/fastrpc-gdsp0"` |
| `alsa-dsp-restart` | `CARD=arduino-monza PCM=MultiMedia1 REMOTEPROC=adsp MIXER="LPI_MI2S_RX_0 Audio Mixer MultiMedia1=on;Headphone Left Switch=on;Headphone Right Switch=on;Headphone Switch=on"` |
| `remoteproc-restart` | `REMOTEPROCS="adsp cdsp gpdsp0"` |
| `memtest` | none; the image boots with `memtest=4`: patterns 0xaaaaaaaaaaaaaaaa, 0x5555555555555555, all ones, all zeros |
| `kvm-unit-tests` | `SKIP_INSTALL=true RESULTS=test REQUIRE_KVM=true CPUS=1-4`: the VMs stay on the Cortex-A78C cluster, since the two clusters have different PMUs and kvmtool gives a VM the PMU of the CPU it starts on. The runner skips the `gicv2-*` tests (the GIC has no GICv2 compatibility, so kvmtool cannot create a GICv2), the migration tests and `pci-test` (QEMU only) and the `mte-*` tests (no MTE). |
| `kvm-guest` | `VCPUS=2 MEMORY=256` |
| `inference` | `PUS="cpu:qnn npu0:qnn-htp:v75:0:cdsp cpu:tflite gpu:tflite-gpu"` |

## Parameters used on the RB3 Gen 2 (QCS6490) and the IQ-9075 EVK (Lemans)

| Definition | RB3 Gen 2 | IQ-9075 EVK |
|---|---|---|
| `fastrpc` | `TESTS="adsp:adsp:0:0 cdsp:cdsp:3:0 cdsp-unsigned-pd:cdsp:3:1"` | `TESTS="adsp:adsp:0:0 cdsp:cdsp:3:0 cdsp-unsigned-pd:cdsp:3:1 cdsp1:cdsp1:4:0 cdsp1-unsigned-pd:cdsp1:4:1" NODES="gpdsp0:/dev/fastrpc-gdsp0 gpdsp1:/dev/fastrpc-gdsp1"` |
| `inference` | `PUS="cpu:qnn npu0:qnn-htp:v68:0:cdsp cpu:tflite gpu:tflite-gpu"` | `PUS="cpu:qnn npu0:qnn-htp:v73:0:cdsp npu1:qnn-htp:v73:1:cdsp1 cpu:tflite gpu:tflite-gpu"` (both NSPs) |

## Parameters used on the Arduino UNO Q (QRB2210)

| Definition | Parameters |
|---|---|
| `video-codec` | `DEVICE=5a00000.video-codec DRIVER=qcom-venus DECODERS="h264 hevc vp9" ENCODERS="h264 hevc" FIRMWARE=/lib/firmware/qcom/venus-6.0/venus.mbn ENCODE_SIZE=1280x736` |
| `remoteproc-restart` | `REMOTEPROCS=adsp EXPECTED_FAIL="adsp=the Linux audio drivers do not survive an ADSP stop"`: SoundWire reads the LPASS core the PAS shutdown has reset (synchronous external abort) and the audio clocks are then disabled twice |
| `inference` | `PUS="cpu:tflite gpu:tflite-gpu" ABSENT="npu=QRB2210 has no Hexagon NSP"` |

The image is a Buildroot initramfs inside a UKI, so the LAVA overlay is
written to an otherwise empty ext4 image flashed to the `rootfs`
partition, and a login command mounts it and links `/lava-<job id>` into
`/`. `dmesg -n 1` in the login commands keeps kernel console messages from
interleaving with the test shell signals; the tests read the complete
kernel log with `dmesg`.

## SystemReady ACS job

A separate job runs the Arm SystemReady devicetree band ACS
([arm-systemready](https://github.com/ARM-software/arm-systemready),
prebuilt `systemready-dt_acs_live_image.wic`) on the same firmware. The
image has two partitions: `BOOT_ACS`, an ESP with GRUB, the UEFI shell,
SCT, BSA and PFDI, the ACS Linux kernel and initramfs, and the results
directory, and `root`, the ACS Linux root filesystem (FWTS, BSA Linux,
dt-validate, Arm's result parsers). The job flashes the ESP to the board's
`efi` partition and the root filesystem, grown so LAVA can add its
overlay, to `rootfs`; the ACS kernel command line names its root by
PARTUUID, so it is pointed at the board's `rootfs` partition. The
devicetree is the firmware's: U-Boot's EFI boot manager installs the
control DT, or `/dtb/<fdtfile>` from the ESP when present.

The ACS then runs unattended across several reboots: SCT (EBBR sequence),
BSA and PFDI in the UEFI shell, a reset, the ACS Linux (FWTS, BSA, the DT
checks, block devices, ethtool, PSCI, SMBIOS, the systemready-scripts
checks), a reboot for the capsule update step, and the ACS Linux again,
which parses every log with Arm's log parser into
`acs_results/acs_summary` and prints `ACS automated test suites run is
completed.`. The job:

- checks the firmware fingerprints on the cold boot (monitor up to `UEFI
  Interactive Shell`) and on every later boot (one monitor until `Please
  wait acs results are syncing on storage medium`, whose pattern also
  matches a banner carrying another fingerprint of the same scheme and
  maps it to `fail`); the ACS resets the board many times (SCT watchdog
  and reset tests, SCT, BSA, PFDI, the capsule step), 17 times on the
  boards below;
- logs in to the ACS Linux: root is logged in on the console already, so
  a `minimal` boot with `kernel-start-message: ""` waits for the
  completion line, printed 60 s after the monitor's end, and sends `root`
  to get a fresh prompt;
- runs `systemready-acs` once per suite: `acs` (Arm's compliance verdict
  per ACS suite and overall, the fingerprint in the SMBIOS BIOS version,
  and, with `DUMP=true`, the results as a base64 tarball in the log),
  `sct`, `bsa`, `fwts`, `dt`, `standalone`, `pfdi`, `post-script`; each
  case is Arm's result for one test (an SCT test, a BSA rule, an FWTS
  test, a DT check), grouped in test sets by the ACS sub suite, with
  Arm's reasons attached to the failing ones;
- powers the board off.
