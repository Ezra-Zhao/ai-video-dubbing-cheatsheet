#!/usr/bin/env bash
# dub_pipeline.sh — batch AI dubbing pipeline
#
#   segments (.txt, one per script segment)
#     → cloud TTS per segment (3 retries, exponential backoff)
#     → empty-audio QA after every segment (ffprobe + silence detect)
#     → phrase-blacklist auto-replacement on persistent failures
#     → concat with 300ms silence between segments
#     → two-pass loudnorm to -16 LUFS
#     → optional BGM duck-mix
#     → master mp3
#
# Usage:
#   ./dub_pipeline.sh --lang es --segments ./segments/es/ --out ./output/
#   ./dub_pipeline.sh --lang es --segments ./segments/es/ --out ./output/ --dry-run
#   ./dub_pipeline.sh --lang en --segments ./segments/en/ --out ./output/ --bgm bgm.mp3 --rate 1.0
#
# Requires (unless --dry-run): TTS_API_KEY, TTS_API_URL, ffmpeg, ffprobe, python3.
#   TTS_API_URL must accept POST JSON {"text","voice","language","rate"} and return raw audio bytes.
#   Adapt tts_synthesize() to your provider's request format.

set -euo pipefail

LANG_CODE="en"
SEGMENTS_DIR=""
OUT_DIR="./output"
DRY_RUN=0
VOICE_ID=""
RATE="1.0"
BGM=""
MAX_RETRIES=3
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BLACKLIST="$SCRIPT_DIR/phrase_blacklist.tsv"

usage() {
  echo "Usage: $0 --lang CODE --segments DIR --out DIR [--dry-run] [--voice ID] [--rate R] [--bgm FILE]"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lang)     LANG_CODE="$2"; shift 2 ;;
    --segments) SEGMENTS_DIR="$2"; shift 2 ;;
    --out)      OUT_DIR="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
    --voice)    VOICE_ID="$2"; shift 2 ;;
    --rate)     RATE="$2"; shift 2 ;;
    --bgm)      BGM="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -z "$SEGMENTS_DIR" || ! -d "$SEGMENTS_DIR" ]] && { echo "ERROR: --segments dir missing: $SEGMENTS_DIR" >&2; usage; }
mkdir -p "$OUT_DIR"

if [[ "$DRY_RUN" -eq 0 ]]; then
  [[ -z "${TTS_API_KEY:-}" ]] && { echo "ERROR: TTS_API_KEY not set" >&2; exit 1; }
  [[ -z "${TTS_API_URL:-}" ]] && { echo "ERROR: TTS_API_URL not set" >&2; exit 1; }
  command -v ffmpeg >/dev/null || { echo "ERROR: ffmpeg not found" >&2; exit 1; }
  command -v ffprobe >/dev/null || { echo "ERROR: ffprobe not found" >&2; exit 1; }
fi

# --- TTS call (adapt request body to your provider) ---
tts_synthesize() { # $1=text $2=voice $3=lang $4=rate $5=outfile
  local text="$1" voice="$2" lang="$3" rate="$4" outfile="$5"
  local payload
  payload="$(python3 -c 'import json,sys; print(json.dumps({"text":sys.argv[1],"voice":sys.argv[2],"language":sys.argv[3],"rate":float(sys.argv[4])}))' \
    "$text" "$voice" "$lang" "$rate")"
  curl -sS --fail --max-time 120 -X POST "$TTS_API_URL" \
    -H "Authorization: Bearer $TTS_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$payload" -o "$outfile"
}

# --- retry with exponential backoff ---
with_retry() { # $1=max_attempts, rest=command
  local max="$1"; shift
  local attempt=1 delay=2
  while (( attempt <= max )); do
    if "$@"; then return 0; fi
    echo "  [retry] attempt $attempt/$max failed, waiting ${delay}s..." >&2
    sleep "$delay"; delay=$((delay * 2)); attempt=$((attempt + 1))
  done
  return 1
}

# --- blacklist lookup: lang<TAB>bad<TAB>good ---
blacklist_replace() { # $1=lang $2=textfile (in place)
  local lang="$1" file="$2"
  [[ -f "$BLACKLIST" ]] || return 0
  while IFS=$'\t' read -r bl bad good; do
    [[ -z "$bl" || "$bl" == \#* ]] && continue
    if [[ "$bl" == "$lang" ]] && grep -qF "$bad" "$file"; then
      echo "  [blacklist] replacing phrase for $lang: '$bad' -> '$good'"
      python3 - "$file" "$bad" "$good" <<'EOF'
import sys
p, bad, good = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p, encoding="utf-8").read().replace(bad, good)
open(p, "w", encoding="utf-8").write(s)
EOF
      return 0
    fi
  done < "$BLACKLIST"
  return 1
}

# --- single-file QA: 0=good, 1=bad ---
qa_one() { # $1=mp3
  python3 "$SCRIPT_DIR/check_audio.py" --quiet "$1"
}

# --- main: dub each segment ---
mapfile -t SEG_FILES < <(ls "$SEGMENTS_DIR"/*.txt 2>/dev/null | sort)
[[ ${#SEG_FILES[@]} -eq 0 ]] && { echo "ERROR: no .txt segments in $SEGMENTS_DIR" >&2; exit 1; }

echo "== dubbing ${#SEG_FILES[@]} segments (lang=$LANG_CODE, dry-run=$DRY_RUN) =="
DUBBED=()
i=0
for seg in "${SEG_FILES[@]}"; do
  i=$((i + 1))
  base="$(basename "$seg" .txt)"
  out_mp3="$OUT_DIR/${base}.dub.mp3"
  text="$(cat "$seg")"
  echo "[$i/${#SEG_FILES[@]}] $base (${#text} chars)"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "  [dry-run] would POST ${#text} chars to TTS -> $out_mp3"
    DUBBED+=("$out_mp3")
    continue
  fi

  work_txt="$(mktemp)"
  printf '%s' "$text" > "$work_txt"
  ok=0
  for round in 1 2 3 4; do
    if with_retry "$MAX_RETRIES" tts_synthesize "$(cat "$work_txt")" "$VOICE_ID" "$LANG_CODE" "$RATE" "$out_mp3"; then
      if qa_one "$out_mp3"; then
        echo "  [ok] $out_mp3 passed QA"
        ok=1; break
      else
        echo "  [warn] $out_mp3 failed QA (empty/silent?)"
      fi
    else
      echo "  [warn] TTS request failed after $MAX_RETRIES attempts"
    fi
    if [[ "$round" -lt 4 ]] && blacklist_replace "$LANG_CODE" "$work_txt"; then
      echo "  [info] rephrased via blacklist, re-dubbing..."
    elif [[ "$round" -eq 4 ]]; then
      break
    fi
  done
  rm -f "$work_txt"
  if [[ "$ok" -eq 0 ]]; then
    echo "ERROR: segment $base failed permanently — fix manually, then re-run" >&2
    exit 1
  fi
  DUBBED+=("$out_mp3")
done

# --- concat with 300ms silence between segments ---
echo "== concatenating ${#DUBBED[@]} segments =="
SILENCE="$OUT_DIR/_silence_03.mp3"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[dry-run] would generate 300ms silence, concat, loudnorm, mix -> $OUT_DIR/master.mp3"
  echo "DONE (dry-run)"
  exit 0
fi

ffmpeg -hide_banner -loglevel error -f lavfi -i anullsrc=r=48000:cl=stereo -t 0.3 \
  -acodec libmp3lame -q:a 9 "$SILENCE" -y
LIST="$OUT_DIR/_concat_list.txt"
: > "$LIST"
for m in "${DUBBED[@]}"; do
  echo "file '$m'" >> "$LIST"
  echo "file '$SILENCE'" >> "$LIST"
done
RAW="$OUT_DIR/_raw_concat.mp3"
ffmpeg -hide_banner -loglevel error -f concat -safe 0 -i "$LIST" -c copy "$RAW" -y

# --- two-pass loudnorm to -16 LUFS ---
echo "== loudnorm (two-pass, target -16 LUFS) =="
MEASURED_JSON="$(ffmpeg -hide_banner -i "$RAW" -af loudnorm=print_format=json -f null - 2>&1 \
  | sed -n '/{/,/}/p')"
get_j() { python3 -c "import json,sys; print(json.load(sys.stdin)['$1'])" <<< "$MEASURED_JSON"; }
NORMED="$OUT_DIR/_normed.mp3"
ffmpeg -hide_banner -loglevel error -i "$RAW" -af \
  "loudnorm=I=-16:TP=-1.5:LRA=11:measured_I=$(get_j input_i):measured_TP=$(get_j input_tp):measured_LRA=$(get_j input_lra):measured_thresh=$(get_j input_thresh):offset=$(get_j target_offset):linear=true" \
  -ar 48000 "$NORMED" -y

# --- optional BGM duck-mix ---
MASTER="$OUT_DIR/master.mp3"
if [[ -n "$BGM" ]]; then
  echo "== mixing with BGM (ducked -20dB) =="
  ffmpeg -hide_banner -loglevel error -i "$NORMED" -i "$BGM" -filter_complex \
    "[1:a]volume=0.15[bg];[0:a][bg]amix=inputs=2:duration=first:dropout_transition=2" \
    -c:a libmp3lame -b:a 192k "$MASTER" -y
else
  cp "$NORMED" "$MASTER"
fi

# --- final QA on master ---
echo "== final QA =="
if qa_one "$MASTER"; then
  echo "DONE: $MASTER"
else
  echo "ERROR: master failed QA: $MASTER" >&2
  exit 1
fi
