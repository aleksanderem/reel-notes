#!/usr/bin/env bash
# Downloads a reel and prepares material for Claude to watch:
# video, caption with comments, frames at scene changes, contact sheets, speech transcript.
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
      likes: .likesCount, views: (.videoPlayCount // .videoViewCount),
      first_comment: .firstComment,
      comments: [(.latestComments // [])[] | {author: .ownerUsername, text: .text}]
    }' <<<"$item" > "$dir/meta.json"

  local video_url
  video_url=$(jq -r '.videoUrl // empty' <<<"$item")
  if [[ -n "$video_url" ]]; then
    curl -sfL -o "$dir/video.mp4" "$video_url"
  else
    # Carousel or photo post: the images become the "frames".
    mkdir -p "$dir/frames"
    local i=0
    jq -r '[(.images // [])[], (.childPosts // [])[].displayUrl, .displayUrl] | map(select(. != null)) | unique[]' <<<"$item" |
      while read -r img; do
        i=$((i + 1))
        curl -sfL -o "$dir/frames/scene_$(printf %03d "$i").jpg" "$img"
      done
  fi
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

extract_frames() {
  local dir="$1"
  mkdir -p "$dir/frames"
  # One frame per scene change (at most every 0.4 s) and at least one every MAX_GAP_S seconds,
  # so a talking head without cuts still yields something to look at.
  local sel="isnan(prev_selected_t)+gt(scene,${SCENE_THRESHOLD})*gte(t-prev_selected_t,0.4)+gte(t-prev_selected_t,${MAX_GAP_S})"
  ffmpeg -hide_banner -nostats -y -i "$dir/video.mp4" \
    -vf "select='${sel}',scale=540:-2,showinfo" -fps_mode vfr "$dir/frames/scene_%03d.jpg" 2>&1 |
    grep -o 'pts_time:[0-9.]*' | cut -d: -f2 |
    awk '{printf "scene_%03d.jpg\t%.1f\n", NR, $1}' > "$dir/frames.tsv"
}

make_sheets() {
  local dir="$1"
  rm -f "$dir"/sheet_*.jpg
  ffmpeg -v error -y -pattern_type glob -i "$dir/frames/scene_*.jpg" \
    -vf "scale=270:-2,tile=${SHEET_COLS}x${SHEET_ROWS}:padding=4:color=white" \
    -fps_mode passthrough "$dir/sheet_%02d.jpg"
}

transcribe() {
  local dir="$1"
  if [[ -z "$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$dir/video.mp4")" ]]; then
    echo "(video has no audio track)" > "$dir/transcript.txt"
    return
  fi
  need whisper-cli "brew install whisper-cpp"
  [[ -f "$WHISPER_MODEL" ]] || { echo "ERROR: whisper model not found: $WHISPER_MODEL (set REEL_NOTES_WHISPER_MODEL)" >&2; exit 2; }
  ffmpeg -v error -y -i "$dir/video.mp4" -ar 16000 -ac 1 "$dir/audio.wav"
  whisper-cli -m "$WHISPER_MODEL" -f "$dir/audio.wav" -l auto -otxt -osrt -of "$dir/transcript" -np >/dev/null 2>&1
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
if [[ -f "$DIR/video.mp4" ]]; then
  [[ -f "$DIR/frames.tsv" && "$FORCE" != 1 ]] || { extract_frames "$DIR"; make_sheets "$DIR"; }
  [[ -f "$DIR/transcript.txt" && "$FORCE" != 1 ]] || transcribe "$DIR"
  DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$DIR/video.mp4" | cut -d. -f1)
else
  ls "$DIR/frames" | awk '{printf "%s\t-\n", $1}' > "$DIR/frames.tsv"
  make_sheets "$DIR"
  echo "(post without video — images only)" > "$DIR/transcript.txt"
fi

FRAMES=$(wc -l < "$DIR/frames.tsv" | tr -d ' ')
SHEETS=$(ls "$DIR"/sheet_*.jpg 2>/dev/null | wc -l | tr -d ' ')
cat <<EOF
DONE
dir:          $DIR
platform:     $PLATFORM
id:           $ID
author:       $(jq -r '.author' "$DIR/meta.json")
duration:     ${DURATION} s
frames:       $FRAMES (timestamps: frames.tsv)
sheets:       $SHEETS (sheet_NN.jpg, ${SHEET_COLS}x${SHEET_ROWS} frames each, row by row)
caption:      meta.json
speech:       transcript.txt (with timestamps: transcript.srt)
EOF
