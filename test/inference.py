#!/usr/bin/env python3
"""Host checks for inference command selection and profile failure handling."""

import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / "automated/linux/inference/inference.sh"


class InferenceTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)
        source = SOURCE.read_text()
        self.functions = source[
            source.index("rproc_path() {") : source.index("# Inputs:")
        ]
        self.env = dict(
            os.environ,
            QBIN=str(self.work),
            QLIB="/sdk/lib",
            MODEL_DIR="/model",
            TFLITE="model.tflite",
            WARMUP="2",
            WORK=str(self.work),
            ARGS=str(self.work / "args"),
            PATH=f"{self.work}:" + os.environ["PATH"],
        )
        self.stub("qnn-net-run", 'printf "%s\\n" "$@" > "$ARGS"\nexit "${RUN_RC:-0}"\n')
        self.stub("tflite-run", 'printf "%s\\n" "$@" > "$ARGS"\nexit "${RUN_RC:-0}"\n')
        self.stub(
            "qnn-profile-viewer",
            'while [ "$#" -gt 0 ]; do\n'
            'if [ "$1" = --output ]; then cp "$PROFILE" "$2"; fi\n'
            'shift\ndone\nexit "${PROFILE_RC:-0}"\n',
        )

    def stub(self, name, body):
        p = self.work / name
        p.write_text("#!/bin/sh\n" + body)
        p.chmod(0o755)

    def run_shell(self, body, **env):
        helpers = (
            "info_msg() { :; }\n"
            'report_fail() { echo "fail $1"; }\n'
            'add_metric() { echo "metric $*"; }\n'
        )
        return subprocess.run(
            ["/bin/sh", "-c", helpers + self.functions + body],
            env=dict(self.env, **env),
            text=True,
            capture_output=True,
        )

    def qnn(self, backend, config="", **env):
        out = str(self.work / "run")
        body = "qnn_run " + " ".join(
            map(shlex.quote, [out, backend, "/model/a.dlc", "/inputs", config])
        )
        proc = self.run_shell(body, **env)
        args = (self.work / "args").read_text().splitlines()
        return proc, args

    def test_htp_is_synchronous_with_config(self):
        proc, args = self.qnn("libQnnHtp.so", "/config")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(args.count("--synchronous"), 1)
        self.assertEqual(args[-2:], ["--config_file", "/config"])

    def test_cpu_arguments_unchanged(self):
        proc, args = self.qnn("libQnnCpu.so")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(
            args,
            [
                "--backend",
                "/sdk/lib/libQnnCpu.so",
                "--model",
                "/sdk/lib/libQnnModelDlc.so",
                "--dlc_path",
                "/model/a.dlc",
                "--input_list",
                "/inputs",
                "--output_dir",
                str(self.work / "run"),
                "--profiling_level",
                "basic",
            ],
        )

    def test_tflite_cpu_and_gpu_arguments_unchanged(self):
        for options in ("--delegate xnnpack --threads 4", "--delegate gpu --gpu_fp16"):
            with self.subTest(options=options):
                proc = self.run_shell(f'tflite_run "$WORK/run" /inputs {options}')
                self.assertEqual(proc.returncode, 0, proc.stderr)
                self.assertEqual(
                    (self.work / "args").read_text().splitlines(),
                    [
                        "--model",
                        "/model/model.tflite",
                        "--input_list",
                        "/inputs",
                        "--output_dir",
                        str(self.work / "run"),
                    ]
                    + options.split(),
                )

    def test_runner_failure_propagates(self):
        for backend in ("libQnnCpu.so", "libQnnHtp.so"):
            with self.subTest(backend=backend):
                proc, _ = self.qnn(backend, RUN_RC="17")
                self.assertEqual(proc.returncode, 17)
        proc = self.run_shell(
            'tflite_run "$WORK/run" /inputs --delegate gpu', RUN_RC="19"
        )
        self.assertEqual(proc.returncode, 19)

    def profile(self, content, **env):
        p = self.work / "input.csv"
        p.write_text(content)
        (self.work / "profile").mkdir(exist_ok=True)
        return self.run_shell(
            'lat=$(qnn_latency "$WORK/profile"); rc=$?\n'
            'latency_cases npu0-qnn-htp "$lat"\nexit "$rc"',
            PROFILE=str(p),
            **env,
        )

    def test_profile_filters_netrun_and_drops_warmup(self):
        proc = self.profile(
            "a,EXECUTE,9000,us,NETRUN\na,EXECUTE,8000,us,NETRUN\n"
            "a,EXECUTE,99999,us,BACKEND\na,FINALIZE,99999,us,NETRUN\n"
            "a,EXECUTE,300,us,NETRUN\na,EXECUTE,400,us,NETRUN\n"
            "a,EXECUTE,500,us,NETRUN\n"
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(
            proc.stdout.splitlines(),
            [
                "metric npu0-qnn-htp-latency pass 0.400 ms",
                "metric npu0-qnn-htp-latency-p50 pass 0.400 ms",
                "metric npu0-qnn-htp-latency-p90 pass 0.500 ms",
            ],
        )

    def test_profile_failure_fails_all_latency_cases(self):
        proc = self.profile("a,EXECUTE,400,us,NETRUN\n", PROFILE_RC="23")
        self.assertEqual(proc.returncode, 1)
        self.assertEqual(proc.stdout.count("fail npu0-qnn-htp-latency"), 3)
        self.assertNotIn("metric", proc.stdout)

    def test_empty_profile_fails_all_latency_cases(self):
        proc = self.profile("a,EXECUTE,400,us,BACKEND\n")
        self.assertEqual(proc.stdout.count("fail npu0-qnn-htp-latency"), 3)
        self.assertNotIn("metric", proc.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
