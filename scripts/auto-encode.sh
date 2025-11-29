#!/usr/bin/env bash

set -uo pipefail

############################################
# Colors
############################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

############################################
# Usage / arguments
############################################

usage() {
  cat <<EOF
Usage: $0 --media=<anime|movie|cartoon> <root_folder>

Examples:
  $0 --media=anime   /path/to/anime
  $0 --media=movie   /path/to/movies
  $0 --media=cartoon /path/to/cartoons

This script:
  - recursively scans the folder
  - extracts width/height and video bitrate
  - calculates a recommended AV1 bitrate for this media type,
    scaling from a 1080p baseline using pixel count
  - re-encodes to AV1 files whose bitrate is > 10% above the recommendation
EOF
}

if [ "$#" -lt 2 ]; then
  usage
  exit 1
fi

MEDIA_KIND=""
ROOT_DIR=""

# Basic argument parsing
for arg in "$@"; do
  case "$arg" in
    --media=*)
      MEDIA_KIND="${arg#*=}"
      ;;
    --media)
      shift
      MEDIA_KIND="${1:-}"
      ;;
    -*)
      echo -e "${RED}Unknown option: $arg${RESET}"
      usage
      exit 1
      ;;
    *)
      if [ -z "${ROOT_DIR:-}" ]; then
        ROOT_DIR="$arg"
      fi
      ;;
  esac
done

if [ -z "$MEDIA_KIND" ] || [ -z "$ROOT_DIR" ]; then
  usage
  exit 1
fi

case "$MEDIA_KIND" in
  anime|movie|cartoon) ;;
  *)
    echo -e "${RED}ERROR: --media must be 'anime', 'movie' or 'cartoon'.${RESET}"
    exit 1
    ;;
esac

echo -e "${BOLD}=== Bitrate / Resolution Analysis ===${RESET}"
echo -e "Media type : ${CYAN}$MEDIA_KIND${RESET}"
echo -e "Folder     : ${CYAN}$ROOT_DIR${RESET}"
echo -e "Threshold  : ${YELLOW}+10% above recommended bitrate${RESET}"
echo

############################################
# Video extensions
############################################

VIDEO_EXTENSIONS=(
  "*.mkv"
  "*.mp4"
  "*.mov"
  "*.avi"
  "*.ts"
  "*.m4v"
  "*.webm"
)

############################################
# Check ffprobe / ffmpeg
############################################

if ! command -v ffprobe >/dev/null 2>&1; then
  echo -e "${RED}ERROR: ffprobe not found in PATH${RESET}"
  exit 1
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo -e "${RED}ERROR: ffmpeg not found in PATH${RESET}"
  exit 1
fi

############################################
# Utility functions
############################################

# Retrieve video bitrate in kb/s (video-only if possible)
get_video_bitrate_kbps() {
  local file="$1"

  # 1) Duration in seconds (float)
  local duration
  duration=$(ffprobe -v error \
    -show_entries format=duration \
    -of csv=p=0 \
    "$file" 2>/dev/null)

  duration=${duration%%,*}  # remove trailing CSV stuff

  if [[ -z "$duration" || "$duration" == "N/A" || "$duration" == "0" ]]; then
    echo ""
    return
  fi

  # 2) File size in bytes
  local size
  size=$(stat -c%s "$file" 2>/dev/null || echo "")
  if [[ -z "$size" || "$size" == "0" ]]; then
    echo ""
    return
  fi

  # 3) Total bitrate (all streams) in kb/s
  local total_kbps
  total_kbps=$(awk -v size="$size" -v dur="$duration" \
    'BEGIN { if (dur > 0) printf "%d", ((size*8)/1000)/dur; }')

  if [[ -z "$total_kbps" || "$total_kbps" == "0" ]]; then
    echo ""
    return
  fi

  # 4) Sum of audio bitrates (if available)
  local audio_bits
  audio_bits=$(ffprobe -v error \
    -select_streams a \
    -show_entries stream=bit_rate \
    -of csv=p=0 \
    "$file" 2>/dev/null \
    | awk 'NF && $1 != "N/A" { s+=$1 } END { print s+0 }')

  if [[ -n "$audio_bits" && "$audio_bits" -gt 0 ]]; then
    local audio_kbps
    audio_kbps=$(awk -v ab="$audio_bits" 'BEGIN { printf "%d", ab/1000 }')

    local video_kbps=$(( total_kbps - audio_kbps ))

    if (( video_kbps > 0 )); then
      echo "$video_kbps"
      return
    fi
  fi

  # Fallback: if audio bitrate not available, return total
  echo "$total_kbps"
}


# Retrieve width & height (pixels)
get_video_dimensions() {
  local file="$1"
  local wh

  wh=$(ffprobe -v error \
    -select_streams v:0 \
    -show_entries stream=width,height \
    -of csv=p=0:s=x \
    "$file" 2>/dev/null || true)

  if [ -z "${wh:-}" ] || [[ "$wh" != *x* ]]; then
    echo ""
    return
  fi

  echo "$wh"
}

# Resolution label based on height (for display)
resolution_label_from_height() {
  local height="$1"

  if   (( height >= 2160 )); then echo "2160p"
  elif (( height >= 1440 )); then echo "1440p"
  elif (( height >= 1080 )); then echo "1080p"
  elif (( height >= 720  )); then echo "720p"
  elif (( height >= 576  )); then echo "576p"
  elif (( height >= 480  )); then echo "480p"
  else echo "${height}p"
  fi
}

# Recommended bitrate (kb/s) by media type + pixel count
get_recommended_bitrate_kbps() {
  local media="$1"
  local pixels="$2"

  # 1920x1080
  local ref_pixels=2073600

  local base_1080
  case "$media" in
    anime)
      base_1080=2500
      ;;
    movie)
      base_1080=4000
      ;;
    cartoon)
      base_1080=1700
      ;;
    *)
      base_1080=2500
      ;;
  esac

  local reco=$(( base_1080 * pixels / ref_pixels ))

  if (( reco < 500 )); then
    reco=500
  fi

  echo "$reco"
}

############################################
# File scanning
############################################

echo -e "${BOLD}Scanning video files...${RESET}"
echo

found_any=false
count_total=0
count_candidates=0
count_skipped_meta=0
count_reencoded=0

total_bitrate=0
total_reco=0

pattern_expr=()
for ext in "${VIDEO_EXTENSIONS[@]}"; do
  if [ "${#pattern_expr[@]}" -gt 0 ]; then
    pattern_expr+=( -o )
  fi
  pattern_expr+=( -iname "$ext" )
done

while IFS= read -r -d '' file; do
  found_any=true

  dims=$(get_video_dimensions "$file")
  bitrate_kbps=$(get_video_bitrate_kbps "$file")

  if [ -z "$dims" ] || [ -z "$bitrate_kbps" ]; then
    echo -e "[${YELLOW}SKIP${RESET}] Missing metadata (dims/bitrate): $file"
    ((count_skipped_meta++))
    continue
  fi

  ((count_total++))

  IFS='x' read -r width height <<< "$dims"
  pixels=$(( width * height ))
  label=$(resolution_label_from_height "$height")
  reco_kbps=$(get_recommended_bitrate_kbps "$MEDIA_KIND" "$pixels")

  threshold=$(( reco_kbps + (reco_kbps / 10) ))

  total_bitrate=$(( total_bitrate + bitrate_kbps ))
  total_reco=$(( total_reco + reco_kbps ))

  echo -e "${MAGENTA}----------------------------------------${RESET}"
  echo -e "${BOLD}File       :${RESET} $file"
  echo -e "${BOLD}Resolution :${RESET} ${CYAN}${width}x${height}${RESET} (${pixels} pixels) → ${CYAN}$label${RESET}"
  echo -e "${BOLD}Bitrate    :${RESET} ${YELLOW}${bitrate_kbps} kb/s${RESET}"
  echo -e "${BOLD}Reco $MEDIA_KIND:${RESET} ${GREEN}${reco_kbps} kb/s${RESET} (threshold +10%: ${GREEN}${threshold} kb/s${RESET})"

  if (( bitrate_kbps > threshold )); then
    echo -e "→ Status    : ${RED}OVERSIZED${RESET} (AV1 re-encode candidate)"
    ((count_candidates++))

    ext="${file##*.}"
    tmp_file="${file%.*}.av1tmp.${ext}"

    echo -e "  ${CYAN}→ Re-encoding to AV1 at ${reco_kbps} kb/s...${RESET}"

    if ffmpeg -hide_banner -loglevel error -stats -nostdin \
      -y -i "$file" \
      -map 0 \
      -c copy \
      -c:v:0 libsvtav1 \
      -b:v:0 "${reco_kbps}k" \
      -preset 6 \
      "$tmp_file" \
      2> >(sed '/^Svt\[info\]:/d; /^SvtMalloc\[info\]:/d' >&2)
    then
      echo -e "  ${GREEN}✅ Encoding complete, replacing original file...${RESET}"
      mv -- "$tmp_file" "$file"
      ((count_reencoded++))
    else
      echo -e "  ${RED}❌ Encoding failed, original file kept.${RESET}"
      rm -f -- "$tmp_file"
    fi

  else
    echo -e "→ Status    : ${GREEN}OK${RESET} (within recommended range)"
  fi

done < <(
  find "$ROOT_DIR" \( -type f -o -type l \) \
    \( "${pattern_expr[@]}" \) -print0 2>/dev/null || true
)

echo
echo -e "${BOLD}=============== SUMMARY ===============${RESET}"

if [ "$found_any" = false ]; then
  echo -e "${YELLOW}No video files found.${RESET}"
  exit 0
fi

echo -e "Videos analyzed                        : ${CYAN}$count_total${RESET}"
echo -e "Files skipped (missing metadata)       : ${YELLOW}$count_skipped_meta${RESET}"
echo -e "Re-encode candidates (> +10%)          : ${MAGENTA}$count_candidates${RESET}"
echo -e "Files re-encoded                       : ${GREEN}$count_reencoded${RESET}"

if (( count_total > 0 )); then
  avg_bitrate=$(( total_bitrate / count_total ))
  avg_reco=$(( total_reco / count_total ))

  avg_bitrate_mbit=$(awk "BEGIN { printf \"%.2f\", $avg_bitrate / 1000 }")
  avg_reco_mbit=$(awk "BEGIN { printf \"%.2f\", $avg_reco / 1000 }")

  echo
  echo -e "${BOLD}Average real bitrate:${RESET} ${YELLOW}${avg_bitrate} kb/s${RESET} (~${YELLOW}${avg_bitrate_mbit} Mb/s${RESET})"
  echo -e "${BOLD}Average recommended  :${RESET} ${GREEN}${avg_reco} kb/s${RESET} (~${GREEN}${avg_reco_mbit} Mb/s${RESET})"
fi

echo
echo -e "${BOLD}=== End of analysis + AV1 re-encoding ===${RESET}"
exit 0
