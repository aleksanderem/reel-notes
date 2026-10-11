#!/usr/bin/env bash
# Extracts full-resolution frames from a time range of a reel — for reading small text.
# Usage: zoom.sh <reel_dir> <from_s> <to_s> [frames_per_second=3] [slide]
#   slide — for carousels: the slide number from frames.tsv (uses slides/NN.mp4 instead of video.mp4)
set -euo pipefail
DIR="${1:?Pass the reel directory}"; FROM="${2:?Pass start time in seconds}"; TO="${3:?Pass end time in seconds}"
FPS="${4:-3}"
SLIDE="${5:-}"
VIDEO="$DIR/video.mp4"
PREFIX="z$(printf '%05.1f' "$FROM" | tr . _)"
if [[ -n "$SLIDE" ]]; then
  VIDEO="$DIR/slides/$(printf %02d "$SLIDE").mp4"
  PREFIX="s$(printf %02d "$SLIDE")_$PREFIX"
fi
[[ -f "$VIDEO" ]] || { echo "ERROR: $VIDEO not found (photo slides are already full size in slides/)" >&2; exit 2; }
mkdir -p "$DIR/hi"
ffmpeg -nostdin -v error -y -ss "$FROM" -to "$TO" -i "$VIDEO" -vf "fps=$FPS" "$DIR/hi/${PREFIX}_%02d.png"
ls "$DIR/hi/${PREFIX}"_*.png
