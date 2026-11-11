#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Qualcomm Technologies, Inc. and/or its subsidiaries.
#
# gen-iris-data.py <out dir> <ffmpeg> [width height frames]: the build-time
# input of iris-secure. An H.264 clip (testsrc, baseline, access unit
# delimiters) and raw NV12 frames (testsrc2), and their ciphertext under
# the secvid test key (../tee-protmem/stream-key.txt, AES-128-CTR, openssl
# enc), each access unit and each frame encrypted on its own from the
# start of the key stream, as the TA decrypts them one at a time. The
# width is a multiple of 128 and the height of 32, so that the codec's
# NV12 layout has no padding.
import os
import subprocess
import sys

out, ffmpeg = sys.argv[1], sys.argv[2]
w, h, n = (int(x) for x in sys.argv[3:6]) if len(sys.argv) > 5 else (512, 256, 30)
# The TA compares frames in 4 KiB chunks
if w * h * 3 // 2 % 4096:
    sys.exit("%dx%d: an NV12 frame must be a multiple of 4096 bytes" % (w, h))
assert w % 128 == 0 and h % 32 == 0
here = os.path.dirname(os.path.abspath(__file__))
key = dict(l.strip().split("=", 1) for l in open(os.path.join(here, "..", "tee-protmem", "stream-key.txt")))


def enc(data):
    r = subprocess.run(["openssl", "enc", "-aes-128-ctr", "-K", key["KEY"], "-iv", key["IV"]],
                       input=data, stdout=subprocess.PIPE, check=True).stdout
    assert len(r) == len(data)
    return r


def ff(*args):
    return subprocess.run([ffmpeg, "-loglevel", "error", "-f", "lavfi", *args, "-"],
                          stdout=subprocess.PIPE, check=True).stdout


clip = ff("-i", "testsrc=size=%dx%d:rate=30" % (w, h), "-frames:v", str(n), "-pix_fmt", "yuv420p", "-c:v", "libx264",
          "-profile:v", "baseline", "-bf", "0", "-g", "15", "-bsf:v", "h264_metadata=aud=insert",
          "-f", "h264")
raw = ff("-i", "testsrc2=size=%dx%d:rate=30" % (w, h), "-frames:v", "8", "-pix_fmt", "nv12",
         "-f", "rawvideo")
# Access units start at each delimiter (NAL type 9)
starts = []
i = 0
while True:
    i = clip.find(b"\x00\x00\x01\x09", i)
    if i < 0:
        break
    s = i - 1 if i > 0 and clip[i - 1] == 0 else i
    starts.append(s)
    i += 4
assert starts and starts[0] == 0, "clip does not start with a delimiter"
aus = [clip[a:b] for a, b in zip(starts, starts[1:] + [len(clip)])]
fsize = w * h * 3 // 2
assert len(raw) == 8 * fsize
os.makedirs(out, exist_ok=True)
open(os.path.join(out, "clip.h264"), "wb").write(clip)
open(os.path.join(out, "clip.idx"), "w").write("".join("%d\n" % len(a) for a in aus))
open(os.path.join(out, "clip.enc"), "wb").write(b"".join(enc(a) for a in aus))
open(os.path.join(out, "raw.enc"), "wb").write(b"".join(enc(raw[k * fsize:(k + 1) * fsize]) for k in range(8)))
open(os.path.join(out, "raw.info"), "w").write("%d %d %d\n" % (w, h, 8))
print("%d access units, %d raw frames of %d bytes" % (len(aus), 8, fsize))
