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
| `cpufreq-policy` | Every policy set to its lowest and highest frequency with the userspace governor and read back, then a stress-ng load on all online CPUs: the load completes and every policy scales up. |
| `maxcpus` | With `maxcpus=N`: N CPUs online at boot, then every other CPU brought online (PSCI CPU_ON of a CPU the firmware has not started). |
| `remoteproc-smoke` | The DSP remoteprocs are running. |
| `fastrpc` | FastRPC round trips to each DSP (signed and unsigned PD) and the FastRPC nodes of DSPs fastrpc_test cannot call. |
| `alsa-dsp-restart` | Playback, a DSP restart while idle and one in the middle of a stream: the DSP and the card come back, the stream ends instead of hanging, playback works again. |
| `optee-xtest` | The OP-TEE regression suite. |
| `gpu-render` | A DRM render node and a headless render with pixel readback (`egl-readback`). |
| `kernel-health` | Kernel warnings, BUGs, oopses, call traces and panics since boot. |

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

## Parameters used on the Arduino VENTUNO Q (QCS8275)

| Definition | Parameters |
|---|---|
| `boot-handoff` | `BOOT_CPU=0x10000 CPUS=8 EXCEPTION_LEVEL=EL2 KVM=vhe TEE=optee PSCI_MODE=osi` |
| `remoteproc-smoke` | `DEVICE="adsp cdsp gpdsp0" WAIT_TIME=30` |
| `fastrpc` | `TESTS="adsp:adsp:0:0 cdsp:cdsp:3:0 cdsp-unsigned-pd:cdsp:3:1" NODES="gpdsp0:/dev/fastrpc-gdsp0"` |
| `alsa-dsp-restart` | `CARD=arduino-monza PCM=MultiMedia1 REMOTEPROC=adsp MIXER="LPI_MI2S_RX_0 Audio Mixer MultiMedia1=on;Headphone Left Switch=on;Headphone Right Switch=on;Headphone Switch=on"` |

The image is a Buildroot initramfs inside a UKI, so the LAVA overlay is
written to an otherwise empty ext4 image flashed to the `rootfs`
partition, and a login command mounts it and links `/lava-<job id>` into
`/`. `dmesg -n 1` in the login commands keeps kernel console messages from
interleaving with the test shell signals; the tests read the complete
kernel log with `dmesg`.
