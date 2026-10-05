#!/usr/bin/env python3
"""check_audio.py — audio QA triple check for dubbed segments.

Flags a file as BAD when any of these hold:
  1. duration < --min-duration (default 0.3s)      → truncated / empty
  2. file size   < --min-size (default 1024 bytes) → empty response saved as mp3
  3. silence ratio > --max-silence (default 0.90)  → TTS returned silence
     (the "Tomemos un respiro." empty-audio trap: API says success, file is silent)

Usage:
    python3 check_audio.py seg01.mp3 seg02.mp3 ...
    python3 check_audio.py --quiet seg01.mp3        # exit 0=good, 1=bad, no output
    python3 check_audio.py --min-duration 0.5 --max-silence 0.8 *.mp3

Exit code: 0 = all good, 1 = at least one bad file (bad ones listed on stdout).
Requires: ffprobe, ffmpeg (for silencedetect).
"""

import argparse
import json
import subprocess
import sys


def ffprobe_duration(path):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "json", path],
        capture_output=True, text=True, check=True,
    )
    return float(json.loads(out.stdout)["format"]["duration"])


def silence_ratio(path, noise_db=-30, min_d=0.5):
    """Fraction of the file detected as silence."""
    import os
    dur = ffprobe_duration(path)
    if dur <= 0:
        return 1.0
    proc = subprocess.run(
        ["ffmpeg", "-hide_banner", "-i", path,
         "-af", f"silencedetect=noise={noise_db}dB:d={min_d}",
         "-f", "null", "-"],
        capture_output=True, text=True,
    )
    silent = 0.0
    for line in proc.stderr.splitlines():
        if "silence_end" in line and "silence_duration" in line:
            try:
                seg = line.split("silence_duration:")[1].split()[0]
                silent += float(seg)
            except (IndexError, ValueError):
                pass
    return min(1.0, silent / dur)


def check_one(path, min_duration, min_size, max_silence):
    import os
    reasons = []
    try:
        size = os.path.getsize(path)
    except OSError as e:
        return False, [f"unreadable: {e}"]
    if size < min_size:
        reasons.append(f"too small ({size}B < {min_size}B)")
    try:
        dur = ffprobe_duration(path)
    except Exception as e:
        return False, [f"ffprobe failed: {e}"]
    if dur < min_duration:
        reasons.append(f"too short ({dur:.2f}s < {min_duration}s)")
    else:
        try:
            ratio = silence_ratio(path)
        except Exception as e:
            return False, [f"silencedetect failed: {e}"]
        if ratio > max_silence:
            reasons.append(f"{ratio:.0%} silent (> {max_silence:.0%}) — likely empty-audio trap")
    return (len(reasons) == 0), reasons


def main():
    ap = argparse.ArgumentParser(description="QA check for dubbed audio segments")
    ap.add_argument("files", nargs="+", help="audio files to check")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--min-duration", type=float, default=0.3)
    ap.add_argument("--min-size", type=int, default=1024)
    ap.add_argument("--max-silence", type=float, default=0.90)
    args = ap.parse_args()

    bad = {}
    for f in args.files:
        ok, reasons = check_one(f, args.min_duration, args.min_size, args.max_silence)
        if not ok:
            bad[f] = reasons
        elif not args.quiet:
            print(f"OK   {f}")

    if bad:
        if not args.quiet:
            for f, reasons in bad.items():
                print(f"BAD  {f}: {'; '.join(reasons)}")
        return 1
    if not args.quiet:
        print(f"all {len(args.files)} file(s) passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
