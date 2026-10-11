#!/usr/bin/env bash
# Downloads a reel and prepares material for Claude to watch:
# video, caption with comments, frames at scene changes, contact sheets, speech transcript.
# Instagram carousels: every slide (photo or video) is saved in order to slides/, video slides
# are cut into frames and transcribed too, and frames.tsv says which slide each frame came from.
#
# Usage: fetch.sh <url>
# Settings (environment variables):
#   REEL_NOTES_MEDIA_DIR        where reel files live (default ~/reel-notes/media)
#   REEL_NOTES_WHISPER_MODEL    whisper.cpp model (default ~/models/ggml-small.bin)
#   REEL_NOTES_SCENE_THRESHOLD  scene-change sensitivity (default 0.08)
#   REEL_NOTES_MAX_GAP_S        longest gap between frames, seconds (default 4)
#   REEL_NOTES_FORCE=1          download and process again even if already on disk
set -euo pipefail

URL="${1:?Pass a reel URL}"
MEDIA_ROOT="${REEL_NOTES_MEDIA_DIR:-$HOME/reel-notes/media}"
WHISPER_MODEL="${REEL_NOTES_WHISPER_MODEL:-$HOME/models/ggml-small.bin}"
SCENE_THRESHOLD="${REEL_NOTES_SCENE_THRESHOLD:-0.08}"
MAX_GAP_S="${REEL_NOTES_MAX_GAP_S:-4}"
FORCE="${REEL_NOTES_FORCE:-0}"
# Paths from settings.json are not shell-expanded, so expand a leading ~ here.
MEDIA_ROOT="${MEDIA_ROOT/#\~/$HOME}"
WHISPER_MODEL="${WHISPER_MODEL/#\~/$HOME}"
SHEET_COLS=6
SHEET_ROWS=4
SHEET_CELL_W=270

need() { command -v "$1" >/dev/null || { echo "ERROR: missing program $1 — install: $2" >&2; exit 2; }; }
need ffmpeg "brew install ffmpeg"
need ffprobe "brew install ffmpeg"
need jq "brew install jq"
need curl "brew install curl"

platform_of() {
  case "$1" in
    *instagram.com/*) echo instagram ;;
    *tiktok.com/*) echo tiktok ;;
    *youtube.com/*|*youtu.be/*) echo youtube ;;
    *facebook.com/*|*fb.watch/*) echo facebook ;;
    *) echo other ;;
  esac
}

instagram_code() {
  sed -nE 's#.*instagram\.com/([^/]+/)?(reel|reels|p|tv)/([A-Za-z0-9_-]+).*#\3#p' <<<"$1"
}

# yt-dlp cannot fetch Instagram without a login, so Instagram goes through Apify.
fetch_instagram() {
  local dir="$1" code="$2"
  need apify "npm i -g apify-cli && apify login"
  local input
  input=$(jq -nc --arg u "https://www.instagram.com/p/$code/" \
    '{directUrls:[$u], resultsType:"posts", resultsLimit:1}')
  apify call apify/instagram-scraper -s -o -i "$input" > "$dir/apify.json"
  local item
  item=$(jq '.[0] // empty' "$dir/apify.json")
  if [[ -z "$item" ]] || jq -e '.error' <<<"$item" >/dev/null; then
    echo "ERROR: Apify returned no post (private account or wrong link). Response: $dir/apify.json" >&2
    exit 3
  fi
  jq --arg url "$URL" --arg id "$code" '{
      url: $url, platform: "instagram", id: $id,
      author: ("@" + (.ownerUsername // "")), author_name: .ownerFullName,
      caption: (.caption // ""), published: ((.timestamp // "")[0:10]),
      duration_s: .videoDuration, type: .type, hashtags: (.hashtags // []),
      slides: ((.childPosts // []) | length),
      likes: .likesCount, views: (.videoPlayCount // .videoViewCount),
      first_comment: .firstComment,
      comments: [(.latestComments // [])[] | {author: .ownerUsername, text: .text}]
    }' <<<"$item" > "$dir/meta.json"

  local video_url slide_count
  video_url=$(jq -r '.videoUrl // empty' <<<"$item")
  slide_count=$(jq '(.childPosts // []) | length' <<<"$item")
  if [[ -n "$video_url" && "$slide_count" == 0 ]]; then
    curl -sfL -o "$dir/video.mp4" "$video_url"
    return
  fi
  # Carousel or photo post: save every slide in order as slides/NN.jpg or slides/NN.mp4.
  # slides.tsv columns: file, kind (image|video), Instagram's alt text.
  mkdir -p "$dir/slides"
  jq -r '(if ((.childPosts // []) | length) > 0 then .childPosts else [.] end) | to_entries[]
      | (.value.videoUrl // "") as $v
      | [(.key + 1), (if $v != "" then "video" else "image" end),
         (if $v != "" then $v else (.value.displayUrl // "") end),
         ((.value.alt // "") | gsub("[\\t\\n]"; " "))]
      | @tsv' <<<"$item" |
    while IFS=$'\t' read -r n kind url alt; do
      [[ -n "$url" ]] || continue
      local file
      file="$(printf %02d "$n").$([[ "$kind" == video ]] && echo mp4 || echo jpg)"
      curl -sfL -o "$dir/slides/$file" "$url"
      printf '%s\t%s\t%s\n' "$file" "$kind" "$alt"
    done > "$dir/slides.tsv"
}

fetch_ytdlp() {
  local tmp="$1"
  need yt-dlp "brew install yt-dlp"
  yt-dlp -q --no-warnings --no-playlist \
    -f 'b[ext=mp4]/bv*+ba/b' --merge-output-format mp4 \
    --write-info-json -o "$tmp/video.%(ext)s" "$URL"
  jq --arg url "$URL" --arg p "$PLATFORM" '{
      url: $url, platform: $p, id: .id,
      author: ("@" + ((.uploader_id // .channel // .uploader // "") | ltrimstr("@"))),
      author_name: (.uploader // .channel),
      caption: ((.title // "") + "\n\n" + (.description // "")),
      published: ((.upload_date // "") | if length == 8 then .[0:4] + "-" + .[4:6] + "-" + .[6:8] else . end),
      duration_s: .duration, type: "Video", hashtags: (.tags // []),
      likes: .like_count, views: .view_count,
      first_comment: null, comments: []
    }' "$tmp/video.info.json" > "$tmp/meta.json"
}

# scene_frames <video> <out_dir>: one frame per scene change (at most every 0.4 s) and at least
# one every MAX_GAP_S seconds, so a talking head without cuts still yields something to look at.
# Writes out_dir/scene_NNN.jpg and prints each frame's second in the video, one per line.
scene_frames() {
  local video="$1" out="$2"
  local sel="isnan(prev_selected_t)+gt(scene,${SCENE_THRESHOLD})*gte(t-prev_selected_t,0.4)+gte(t-prev_selected_t,${MAX_GAP_S})"
  mkdir -p "$out"
  ffmpeg -nostdin -hide_banner -nostats -y -i "$video" \
    -vf "select='${sel}',scale=540:-2,showinfo" -fps_mode vfr "$out/scene_%03d.jpg" 2>&1 |
    grep -o 'pts_time:[0-9.]*' | cut -d: -f2
}

# Empties the frames directory (only scene_*.jpg files are ever written there).
reset_frames() {
  local dir="$1"
  mkdir -p "$dir/frames"
  find "$dir/frames" -maxdepth 1 -name 'scene_*.jpg' -delete
}

# frames.tsv columns: frame file, slide number (1 for a plain reel), second in that slide's video
# ("-" for a photo slide).
extract_frames() {
  local dir="$1"
  reset_frames "$dir"
  scene_frames "$dir/video.mp4" "$dir/frames" |
    awk '{printf "scene_%03d.jpg\t1\t%.1f\n", NR, $1}' > "$dir/frames.tsv"
}

# All slides go into one numbered frame sequence, so the contact sheets show the carousel in order.
extract_slide_frames() {
  local dir="$1" n=0 file kind slide tmp t i
  reset_frames "$dir"
  : > "$dir/frames.tsv"
  while IFS=$'\t' read -r -u 3 file kind _; do
    slide=$((10#${file%%.*}))
    if [[ "$kind" == image ]]; then
      n=$((n + 1))
      cp "$dir/slides/$file" "$dir/frames/$(printf scene_%03d.jpg "$n")"
      printf 'scene_%03d.jpg\t%d\t-\n' "$n" "$slide" >> "$dir/frames.tsv"
      continue
    fi
    tmp=$(mktemp -d "$dir/.frames-XXXXXX")
    i=0
    while read -r t; do
      i=$((i + 1)); n=$((n + 1))
      mv "$tmp/$(printf scene_%03d.jpg "$i")" "$dir/frames/$(printf scene_%03d.jpg "$n")"
      printf 'scene_%03d.jpg\t%d\t%.1f\n' "$n" "$slide" "$t" >> "$dir/frames.tsv"
    done < <(scene_frames "$dir/slides/$file" "$tmp")
    rmdir "$tmp"
  done 3< "$dir/slides.tsv"
}

make_sheets() {
  local dir="$1" first w h cell_h
  find "$dir" -maxdepth 1 -name 'sheet_*.jpg' -delete
  # Every cell gets the first frame's proportions; frames with other proportions are fitted
  # inside it with white margins (carousels mix portrait, square and landscape).
  first=$(ls "$dir"/frames/scene_*.jpg | head -1)
  IFS=x read -r w h < <(ffprobe -v error -select_streams v -show_entries stream=width,height -of csv=p=0:s=x "$first")
  cell_h=$(( (SHEET_CELL_W * h / w + 1) / 2 * 2 ))
  ffmpeg -nostdin -v error -y -reinit_filter 0 -pattern_type glob -i "$dir/frames/scene_*.jpg" \
    -vf "scale=${SHEET_CELL_W}:${cell_h}:force_original_aspect_ratio=decrease,pad=${SHEET_CELL_W}:${cell_h}:(ow-iw)/2:(oh-ih)/2:color=white,tile=${SHEET_COLS}x${SHEET_ROWS}:padding=4:color=white" \
    -fps_mode passthrough "$dir/sheet_%02d.jpg"
}

# transcribe <video> <out_base>: writes out_base.txt and out_base.srt.
transcribe() {
  local video="$1" out="$2"
  if [[ -z "$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$video")" ]]; then
    echo "(video has no audio track)" > "$out.txt"
    return
  fi
  need whisper-cli "brew install whisper-cpp"
  [[ -f "$WHISPER_MODEL" ]] || { echo "ERROR: whisper model not found: $WHISPER_MODEL (set REEL_NOTES_WHISPER_MODEL)" >&2; exit 2; }
  ffmpeg -nostdin -v error -y -i "$video" -ar 16000 -ac 1 "$out.wav"
  whisper-cli -m "$WHISPER_MODEL" -f "$out.wav" -l auto -otxt -osrt -of "$out" -np </dev/null >/dev/null 2>&1
}

# One transcript.txt for the whole carousel, with a heading per video slide;
# per-slide timestamps are in slides/NN.srt.
transcribe_slides() {
  local dir="$1" file kind slide
  : > "$dir/transcript.txt"
  while IFS=$'\t' read -r -u 3 file kind _; do
    [[ "$kind" == video ]] || continue
    slide="${file%%.*}"
    transcribe "$dir/slides/$file" "$dir/slides/$slide"
    printf '### Slide %d (video)\n%s\n\n' "$((10#$slide))" "$(cat "$dir/slides/$slide.txt")" >> "$dir/transcript.txt"
  done 3< "$dir/slides.tsv"
  [[ -s "$dir/transcript.txt" ]] || echo "(no video slides — images only)" > "$dir/transcript.txt"
}

PLATFORM=$(platform_of "$URL")
mkdir -p "$MEDIA_ROOT"

if [[ "$PLATFORM" == instagram ]]; then
  ID=$(instagram_code "$URL")
  [[ -n "$ID" ]] || { echo "ERROR: not a recognizable Instagram post link: $URL" >&2; exit 3; }
  DIR="$MEDIA_ROOT/$ID"
  if [[ "$FORCE" == 1 || ! -f "$DIR/meta.json" ]]; then
    mkdir -p "$DIR"
    fetch_instagram "$DIR" "$ID"
  fi
else
  TMP=$(mktemp -d "$MEDIA_ROOT/.download-XXXXXX")
  trap 'rm -rf "$TMP"' EXIT
  fetch_ytdlp "$TMP"
  ID=$(jq -r '.id' "$TMP/meta.json")
  DIR="$MEDIA_ROOT/$ID"
  if [[ "$FORCE" == 1 || ! -f "$DIR/meta.json" ]]; then
    mkdir -p "$DIR"
    mv "$TMP/video.mp4" "$TMP/meta.json" "$TMP/video.info.json" "$DIR/"
  fi
fi

DURATION="?"
SLIDES="-"
if [[ -f "$DIR/slides.tsv" ]]; then
  [[ -f "$DIR/frames.tsv" && -f "$DIR/sheet_01.jpg" && "$FORCE" != 1 ]] || { extract_slide_frames "$DIR"; make_sheets "$DIR"; }
  [[ -f "$DIR/transcript.txt" && "$FORCE" != 1 ]] || transcribe_slides "$DIR"
  SLIDES="$(wc -l < "$DIR/slides.tsv" | tr -d ' ') ($(grep -c $'\tvideo\t' "$DIR/slides.tsv" || true) video; list: slides.tsv, files: slides/)"
elif [[ ! -f "$DIR/video.mp4" ]]; then
  echo "ERROR: $DIR was downloaded by an older version (no video.mp4, no slides.tsv) — rerun with REEL_NOTES_FORCE=1" >&2
  exit 3
else
  [[ -f "$DIR/frames.tsv" && -f "$DIR/sheet_01.jpg" && "$FORCE" != 1 ]] || { extract_frames "$DIR"; make_sheets "$DIR"; }
  [[ -f "$DIR/transcript.txt" && "$FORCE" != 1 ]] || transcribe "$DIR/video.mp4" "$DIR/transcript"
  DURATION="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$DIR/video.mp4" | cut -d. -f1) s"
fi

FRAMES=$(wc -l < "$DIR/frames.tsv" | tr -d ' ')
SHEETS=$(ls "$DIR"/sheet_*.jpg 2>/dev/null | wc -l | tr -d ' ')
cat <<EOF
DONE
dir:          $DIR
platform:     $PLATFORM
id:           $ID
author:       $(jq -r '.author' "$DIR/meta.json")
duration:     $DURATION
slides:       $SLIDES
frames:       $FRAMES (frames.tsv: frame, slide, second)
sheets:       $SHEETS (sheet_NN.jpg, ${SHEET_COLS}x${SHEET_ROWS} frames each, row by row)
caption:      meta.json
speech:       transcript.txt (with timestamps: transcript.srt, or slides/NN.srt for carousels)
EOF
