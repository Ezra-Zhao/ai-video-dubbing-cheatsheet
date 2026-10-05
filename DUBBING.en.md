# 🎙️ AI Video Dubbing Cheatsheet (English)

> Battle-tested on 60 multilingual tech-explainer videos (6 projects × ZH/EN/ES/PT/HI × 16:9 + 9:16).
> Each video: 5 tech segments + a mid-break culture card + a closing blessing page.
> Pipeline: script → Whisper (QA) → cloud TTS dubbing → ffmpeg mixing → subtitle burn-in → dual-format render.

---

## 0. Pipeline Overview (7 Steps)

```
1. Lock the script (split into segments, budget seconds per segment FIRST)
2. TTS dubbing → one mp3 per segment (chunk it! never feed the whole script at once)
3. Audio QA (empty/silent audio detection, see §3)
4. ffmpeg loudness normalization + tempo alignment
5. Mix (dub + background music, ducked)
6. Subtitles (SRT → bilingual ASS)
7. Dual render: 16:9 landscape / 9:16 portrait crop
```

**Golden rules:**
- One segment, one file: `seg01_intro.en.mp3`. Parallelize per segment; a failure only re-runs one segment.
- Budget seconds before writing copy. Adjust words/speed to fit — never the other way around.
- Always keep a clean no-subtitle master. Burn-in is the last step.

---

## 1. Whisper: Transcription / Translation / Timestamps

### 1.1 Basic Transcription

```bash
# English transcription with word-level timestamps
whisper audio.mp3 --model large-v3 --language en \
  --task transcribe --output_format srt --word_timestamps True \
  --output_dir ./subs

# Translate anything into English
whisper audio.mp3 --model large-v3 --task translate --output_format srt
```

### 1.2 Key Multilingual Parameters

| Flag | What it does | Production value |
|---|---|---|
| `--language` | Source language; auto-detect is slow and misfires | `en`/`es`/`pt`/`zh`/`hi` — **always set explicitly** |
| `--task` | `transcribe` vs `translate` (to English) | transcribe for script QA |
| `--model` | tiny → large-v3 | `large-v3` for finals, `medium` for drafts (half the time) |
| `--initial_prompt` | Terminology hints, fixes proper nouns | `"Cloud-native observability lecture. Terms: Prometheus, Grafana, Kubernetes."` |
| `--condition_on_previous_text` | Context conditioning; off reduces hallucinated repeats | `False` for long audio |
| `--word_timestamps True` | Word-level timestamps | Required for subtitle sync |
| `--vad_filter` | faster-whisper VAD, skips silence | On for long lectures, saves 20–40% |

### 1.3 Long Audio & Hallucination Control

```bash
python3 - <<'EOF'
from faster_whisper import WhisperModel
model = WhisperModel("large-v3", device="cuda", compute_type="float16")
segments, info = model.transcribe(
    "lecture.mp3",
    language="en",
    vad_filter=True,
    vad_parameters=dict(min_silence_duration_ms=500),
    condition_on_previous_text=False,   # kills hallucinated loops
    initial_prompt="Cloud-native lecture. Terms: Prometheus, Grafana, Kubernetes",
    word_timestamps=True,
)
for s in segments:
    print(f"[{s.start:.2f}->{s.end:.2f}] {s.text}")
EOF
```

**Gotchas:**
- Whisper hallucinates lyrics over intro/outro music — trim those with ffmpeg first.
- Word timestamps drift ±1s toward the end of 10+ min audio; align per sentence, then hand-tweak.
- Mixed-language speech: run once per dominant language and merge manually rather than trusting auto-detect.

---

## 2. Cloud TTS Dubbing (VoiceStudio-style services as example)

### 2.1 Voice Selection per Language

| Language | Rule | Production note |
|---|---|---|
| English | US vs UK accent — pick by audience | US for tech explainers, rate 1.0 |
| Spanish | Latin American vs Castilian — pick ONE | **Never mix accents in one video** |
| Portuguese | Brazilian vs European — pick ONE | **Never mix in one video** |
| Chinese | Native neural Mandarin voice | Rate 0.95–1.0; faster swallows characters |
| Hindi | Verify the voice accepts Devanagari input | Some voices only take romanized text — test one sentence first |

### 2.2 Rate / Pause Control (SSML)

```xml
<speak>
  <prosody rate="1.0" pitch="+0%">
    Main narration at natural pace.
  </prosody>
  <break time="600ms"/>
  <prosody rate="0.95">
    Slower for the transition — 600ms breath between sections.
  </prosody>
</speak>
```

- Commas get natural pauses from the engine; **section breaks need hand-written `<break>`** or it sounds rushed.
- Transition lines ("let's take a breather") deserve their own segment + 800ms break.

### 2.3 Long-Text Chunking (Core Technique)

```
Rules:
1. Split on sentence boundaries — never mid-clause
2. ≤ 300 chars per chunk (EN/ES/PT); ≤ 200 chars for Chinese
3. One TTS call per chunk, one file each: seg01.mp3, seg02.mp3...
4. Insert 300ms silence between chunks when concatenating:
```

```bash
ffmpeg -f lavfi -i anullsrc=r=48000:cl=stereo -t 0.3 -q:a 9 -acodec libmp3lame silence_03.mp3 -y
# filelist.txt: file 'seg01.mp3' / file 'silence_03.mp3' / ...
ffmpeg -f concat -safe 0 -i filelist.txt -c copy full_dub.mp3 -y
```

**Why chunking is mandatory:** feeding a whole script to cloud TTS risks timeouts/truncation and, worse, drifting pace and misplaced stress in the second half. All 60 videos were dubbed per-segment. Zero failures.

### 2.4 The Empty-Audio Trap: Detect + Replace (most valuable section here)

**Symptom (reproduced reliably):** certain phrases make TTS return "success" with an empty/silent file.
Real case: the Spanish transition `Tomemos un respiro.` ("let's take a breather") **consistently produced empty audio** on one cloud TTS provider. `Tomemos un descanso.` works fine; `Hagamos una pausa.` (used in another project) works fine too.

**Detect (run after every dub, see `scripts/check_audio.py`):**

```bash
# Quick check: ~0 duration or suspiciously small file
ffprobe -v error -show_entries format=duration,size -of csv=p=0 seg03.mp3

# Silence check: >90% silence = bad file
ffmpeg -i seg03.mp3 -af silencedetect=noise=-30dB:d=0.5 -f null - 2>&1 | grep silencedetect
```

**Recovery flow:**
1. Dubbing script checks every segment immediately; bad segments retry 3× with exponential backoff.
2. Still bad after 3 → look up the phrase blacklist, rephrase, re-dub.
3. Log the triggering phrase into the blacklist so it's avoided next time.

**Blacklist example (Spanish):**

| Bad phrase | Replacement |
|---|---|
| `Tomemos un respiro.` | `Tomemos un descanso.` / `Hagamos una pausa.` |

> Lesson: the TTS text frontend has bugs on specific phrase combinations — it's not about meaning. Don't argue with it; rephrasing is the cheapest fix. Maintain one blacklist per language and reuse across projects.

---

## 3. ffmpeg: Mixing / Loudness / Tempo / Burn-in / Cropping

### 3.1 Extract & Merge

```bash
ffmpeg -i final.mp4 -vn -ac 2 -ar 48000 audio.wav -y   # extract for QA

# Merge dub with video (copy video stream, no re-encode)
ffmpeg -i video_silent.mp4 -i dub.mp3 -c:v copy -map 0:v:0 -map 1:a:0 -shortest out.mp4 -y

# Dub + background music (music at -20dB, ducked under voice)
ffmpeg -i dub.mp3 -i bgm.mp3 -filter_complex \
  "[1:a]volume=0.15[bg];[0:a][bg]amix=inputs=2:duration=first:dropout_transition=2" \
  -c:a aac -b:a 192k mixed.m4a -y
```

### 3.2 Loudness Normalization (mandatory after multi-segment concat)

```bash
# Pass 1: measure
ffmpeg -i full_dub.mp3 -af loudnorm=print_format=json -f null - 2>&1 | grep -A12 Parsed_loudnorm

# Pass 2: normalize with measured values
ffmpeg -i full_dub.mp3 -af \
  "loudnorm=I=-16:TP=-1.5:LRA=11:measured_I=-19.2:measured_TP=-3.1:measured_LRA=7.5:measured_thresh=-29.4:offset=0.83:linear=true" \
  -ar 48000 dub_norm.mp3 -y
```

- Target `I=-16 LUFS` for web video. Segments from different voices/sessions sound cheap without this.
- Single-pass `loudnorm` (no measurement) applies dynamic limiting and degrades quality — **always two-pass for finals**.

### 3.3 Tempo Without Pitch Shift (fit dub to picture)

```bash
ffmpeg -i dub.mp3 -af "atempo=1.2" dub_fast.mp3 -y
# atempo range per filter: 0.5–2.0; chain for more:
ffmpeg -i dub.mp3 -af "atempo=1.5,atempo=1.5" dub_225.mp3 -y   # = 2.25x
```

- Usable range in practice: 0.9–1.15. Beyond that it sounds fake — **rewrite the copy instead of stretching**.
- Rule of thumb: English ~2.5–3 words/sec, Spanish/Portuguese ~3 words/sec. Work backwards to word count.

### 3.4 Subtitle Burn-in

```bash
ffmpeg -i out.mp4 -vf \
  "subtitles=sub.srt:force_style='FontName=DejaVu Sans,FontSize=22,PrimaryColour=&H00FFFFFF,OutlineColour=&H90000000,BorderStyle=1,Outline=2,Shadow=0,MarginV=45'" \
  -c:a copy final_sub.mp4 -y

# Bilingual: build ASS first (see §4), then burn
ffmpeg -i out.mp4 -vf "ass=sub_bilingual.ass" -c:a copy final_sub.mp4 -y
```

**Font trap (hit in production):** mixed scripts (Latin + CJK + Devanagari) render as tofu boxes if the system lacks glyphs. Check coverage before burning:

```bash
fc-match "Noto Sans" --verbose | grep -i charset | head -3
# Nuclear option: per-language Style entries in the ASS, or the full Noto family
```

### 3.5 Landscape ↔ Portrait Cropping

```bash
# 16:9 → 9:16 centered crop at 1080x1920
ffmpeg -i landscape.mp4 -vf "crop=ih*9/16:ih,scale=1080:1920" -c:a copy portrait.mp4 -y

# Key content off-center? Pin the crop window manually (x:y)
ffmpeg -i landscape.mp4 -vf "crop=607:1080:656:0,scale=1080:1920" -c:a copy portrait.mp4 -y

# Subtitles: bump MarginV for portrait or platform UI covers them
# MarginV=120 (portrait) vs MarginV=45 (landscape)
```

---

## 4. Subtitles: SRT Essentials / Bilingual Layout / Timing Tweaks

### 4.1 SRT Format (one missing blank line breaks everything)

```
1
00:00:01,000 --> 00:00:04,500
First subtitle line

2
00:00:05,000 --> 00:00:08,000
Second subtitle line

```
- `HH:MM:SS,mmm` — **comma**, not a dot.
- **Exactly one blank line** between entries, including at EOF.
- ≤ 42 chars/line, ≤ 7 seconds per cue.

### 4.2 Bilingual Subtitles (ASS)

```ini
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:04.50,Top,,0,0,0,,{\fnDejaVu Sans}Source line one\N{\fnNoto Sans CJK SC}译文第二行
```

- `\N` = hard line break; source on top, translation below is the standard layout.
- Portrait video: top-aligned subtitles (`Alignment=8`) dodge the like/comment UI at the bottom.

### 4.3 Timing Tweaks

```bash
# Shift everything +500ms (dub lags picture)
ffmpeg -itsoffset 0.5 -i sub.srt -c copy sub_shifted.srt -y
# Rule: TTS chunk-concat drifts ≈ ±0.3s per minute — align per segment, not per whole video
```

---

## 5. Batch Pipeline Scripts

Two runnable scripts in `scripts/`:

| Script | Does |
|---|---|
| `dub_pipeline.sh` | End-to-end: chunked TTS dubbing (with retries) → empty-audio check → silence-padded concat → loudnorm → mix → master. `--dry-run` supported |
| `check_audio.py` | Audio QA: duration + file-size + silence-ratio triple check, lists bad segments |

```bash
./scripts/dub_pipeline.sh --dry-run --lang en --segments ./segments/   # rehearse, no API calls
./scripts/dub_pipeline.sh --lang en --segments ./segments/ --out ./output/  # needs TTS_API_KEY
python3 scripts/check_audio.py ./segments/en/*.mp3
```

---

## 6. Cost & Time Estimation

### 6.1 Time Model (measured across 60 videos)

| Stage | Time per minute of finished video | Notes |
|---|---|---|
| Script writing/lock | Human-dominated | Biggest time sink — schedule separately |
| TTS dubbing | ~0.5–1× runtime | 3–5 parallel calls; network-bound |
| Whisper transcription QA | GPU ~0.3× / CPU ~3–5× | large-v3 + VAD |
| ffmpeg render | ~0.5–2× | Subtitle burn-in re-encodes — slowest step |
| Human QA listen | ~1× | Must listen fully; skimming misses empty audio |

### 6.2 Cost Model

```
TTS cost ≈ total characters × price per 1k chars
  └─ Count first: wc -m on the script
  └─ Fixed segments (intro/mid-break/outro) are dubbed ONCE and reused
     across language versions — biggest saver

Whisper local = $0 (minus electricity); cloud API billed per minute
ffmpeg = $0
```

### 6.3 Free-Tier Alerts (70% / 90%)

- Log remaining quota on the 1st of each month; the pipeline script counts characters per segment.
- 70% → warning (how many days left?); 90% → freeze new jobs, fixes only.
- **Reusing fixed-segment audio across videos** is the single most effective saver.

---

## 7. Top 8 Production Pitfalls

| # | Pitfall | Symptom | Fix |
|---|---|---|---|
| 1 | **Empty audio** | TTS "succeeds" but file is silent (phrase-specific, e.g. ES `Tomemos un respiro.`) | Always run `check_audio.py` after dubbing; maintain a phrase blacklist |
| 2 | **Tofu boxes** | Missing glyphs in burned subtitles (Devanagari/CJK) | Check font coverage with fc-match; per-language ASS styles |
| 3 | **Whole-script TTS** | Timeouts / drifting pace in latter half | Chunk ≤300 chars on sentence boundaries, 300ms silence between |
| 4 | **Uneven loudness** | Concat of segments sounds amateur | Two-pass loudnorm to -16 LUFS |
| 5 | **Covered subtitles** | 9:16 burn-in hidden under platform UI | Larger MarginV / top alignment |
| 6 | **Whisper hallucinations** | Lyrics transcribed over intro music | Trim intro/outro first; `condition_on_previous_text=False` |
| 7 | **Duration mismatch** | Dub longer/shorter than picture | Budget seconds first (≈2.5–3 wps EN); atempo only for 0.9–1.15 |
| 8 | **Fixed-segment creep** | Mid-break/outro keeps growing | Hard second-budget per fixed segment; cut copy to fit |

---

*Original, clean-room content by the author. All commands verified in production.*
