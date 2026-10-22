#!/usr/bin/env python3
"""Ground-truth beats + downbeats with Beat This! (CPJKU, MIT, ISMIR 2024) for sync evaluation.
Usage: ground_truth.py out_dir file1 [file2 ...]  -> out_dir/<stem>.json {beats:[...], downbeats:[...]}"""
import json, os, subprocess, sys, tempfile
import numpy as np, soundfile as sf
from beat_this.inference import Audio2Beats

out = sys.argv[1]; os.makedirs(out, exist_ok=True)
a2b = Audio2Beats(checkpoint_path="final0", device="mps", dbn=False)
for f in sys.argv[2:]:
    stem = os.path.splitext(os.path.basename(f))[0]
    dst = os.path.join(out, stem + ".json")
    if os.path.exists(dst):
        continue
    with tempfile.NamedTemporaryFile(suffix=".wav") as tmp:   # decode anything (m4a/mp3) with ffmpeg
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", f, "-ac", "1", "-ar", "22050", tmp.name], check=True)
        audio, sr = sf.read(tmp.name, dtype="float32")
    beats, downs = a2b(audio, sr)
    ibi = np.diff(beats)
    bpm = float(60 / np.median(ibi)) if len(ibi) else 0
    json.dump({"file": f.replace(os.path.expanduser("~"), "~", 1), "bpm": bpm, "beats": [float(b) for b in beats], "downbeats": [float(d) for d in downs]}, open(dst, "w"))
    print(f"{stem[:50]:50s} bpm={bpm:6.2f} beats={len(beats)} downbeats={len(downs)}")
