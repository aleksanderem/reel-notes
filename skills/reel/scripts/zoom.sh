#!/usr/bin/env bash
# Extracts full-resolution frames from a time range of a reel — for reading small text.
# Usage: zoom.sh <reel_dir> <from_s> <to_s> [frames_per_second=3]
set -euo pipefail
DIR="${1:?Pass the reel directory}"; FROM="${2:?Pass start time in seconds}"; TO="${3:?Pass end time in seconds}"
FPS="${4:-3}"
[[ -f "$DIR/video.mp4" ]] || { echo "ERROR: $DIR/video.mp4 not found" >&2; exit 2; }
mkdir -p "$DIR/hi"
PREFIX="z$(printf '%05.1f' "$FROM" | tr . _)"
ffmpeg -v error -y -ss "$FROM" -to "$TO" -i "$DIR/video.mp4" -vf "fps=$FPS" "$DIR/hi/${PREFIX}_%02d.png"
ls "$DIR/hi/${PREFIX}"_*.png
