#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Qualcomm Technologies, Inc. and/or its subsidiaries.
#
# gen-stream.py <out dir> [frames] [frame size]: the build-time input of
# tee-protmem. A random "video" whose every 4 KiB page starts with a
# random 32-byte marker, encrypted with AES-128-CTR under the test key in
# stream-key.txt (openssl enc). Writes stream.enc, stream.sha256 (SHA-256
# of each plaintext frame), stream.info and marker.x (the marker XORed with
# 0xa5); the plaintext is never written out.
import hashlib
import os
import subprocess
import sys

out = sys.argv[1]
frames = int(sys.argv[2]) if len(sys.argv) > 2 else 8
fsize = int(sys.argv[3]) if len(sys.argv) > 3 else 32768
assert fsize % 4096 == 0
here = os.path.dirname(os.path.abspath(__file__))
key = dict(line.strip().split("=", 1) for line in open(os.path.join(here, "stream-key.txt")))
marker = os.urandom(32)
plain = bytearray()
for f in range(frames):
    frame = bytearray()
    for p in range(fsize // 4096):
        seed = os.urandom(32)
        body = b"".join(hashlib.sha256(seed + n.to_bytes(4, "little")).digest() for n in range(127))
        frame += marker + body
    plain += frame
enc = subprocess.run(["openssl", "enc", "-aes-128-ctr", "-K", key["KEY"], "-iv", key["IV"]],
                     input=bytes(plain), stdout=subprocess.PIPE, check=True).stdout
assert len(enc) == len(plain)
os.makedirs(out, exist_ok=True)
open(os.path.join(out, "stream.enc"), "wb").write(enc)
with open(os.path.join(out, "stream.sha256"), "w") as f:
    for n in range(frames):
        f.write(hashlib.sha256(plain[n * fsize:(n + 1) * fsize]).hexdigest() + "\n")
open(os.path.join(out, "stream.info"), "w").write("%d %d\n" % (fsize, frames))
open(os.path.join(out, "marker.x"), "wb").write(bytes(b ^ 0xa5 for b in marker))
