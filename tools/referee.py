#!/usr/bin/env python3
"""RAVE LIVE beat referee: Beat This! (CPJKU, MIT licence, ISMIR 2024) run on a sliding window.

The app's own tracker is causal and fast (drives every frame). Every ~1.5 s it sends the last ~12 s of
audio here; Beat This! (non-causal, much more accurate) returns beats + downbeats for that window, and the
app uses them to fix the slow things a causal tracker gets wrong: off-beat phase locks, double/half/
triplet tempo, and where beat 1 of the bar is.

Protocol (stdin/stdout, binary in, JSON lines out):
  in : uint32 n | float64 t_end (stream seconds of the last sample) | n x float32 mono @ 22050 Hz
  out: {"t_end": t, "beats": [stream s...], "downbeats": [stream s...], "ms": inference_ms}
"""
import json, struct, sys, time, warnings
warnings.filterwarnings("ignore")
import numpy as np
import torch
torch.set_num_threads(2)
from beat_this.inference import Audio2Beats

SR = 22050
model = Audio2Beats(checkpoint_path="final0", device="cpu", dbn=False)
inp, out = sys.stdin.buffer, sys.stdout
out.write(json.dumps({"ready": True}) + "\n"); out.flush()
while True:
    hdr = inp.read(12)
    if len(hdr) < 12:
        break
    n, t_end = struct.unpack("<Id", hdr)
    buf = inp.read(n * 4)
    if len(buf) < n * 4:
        break
    x = np.frombuffer(buf, dtype="<f4").astype(np.float32)
    t0 = time.time()
    try:
        beats, downs = model(x, SR)
    except Exception as e:  # never kill the show over one bad window
        out.write(json.dumps({"t_end": t_end, "error": str(e)[:200]}) + "\n"); out.flush(); continue
    start = t_end - n / SR
    out.write(json.dumps({"t_end": t_end, "beats": [start + float(b) for b in beats],
                          "downbeats": [start + float(d) for d in downs],
                          "ms": round((time.time() - t0) * 1000, 1)}) + "\n")
    out.flush()
