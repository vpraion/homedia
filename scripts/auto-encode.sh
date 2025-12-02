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
  - extracts width/height and video codec
  - chooses a base AV1 CRF depending on media type
  - slightly adjusts CRF based on pixel count vs 1080p
  - re-encodes to AV1 (libsvtav1) ONLY if video is not already AV1
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

echo -e "${BOLD}=== AV1 / CRF re-encoding ===${RESET}"
echo -e "Media type : ${CYAN}$MEDIA_KIND${RESET}"
echo -e "Folder     : ${CYAN}$ROOT_DIR${RESET}"
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

# Get video codec name (v:0)
get_video_codec() {
  local file="$1"
  ffprobe -v error \
    -select_streams v:0 \
    -show_entries stream=codec_name \
    -of csv=p=0 \
    "$file" 2>/dev/null || echo ""
}

# Base CRF by media type
choose_base_crf() {
  local media="$1"
  local base_crf

  case "$media" in
    anime)
      # animes encodent très bien → CRF assez haut
      base_crf=31
      ;;
    cartoon)
      # cartoons encore plus simples
      base_crf=32
      ;;
    movie)
      # films live action → CRF plus bas
      base_crf=26
      ;;
    *)
      base_crf=26
      ;;
  esac

  echo "$base_crf"
}

# Adjust CRF based on resolution buckets around 1080p
adjust_crf_by_pixels() {
  local base_crf="$1"
  local pixels="$2"

  # 1920x1080 pixels
  local ref_pixels=2073600

  # integer ratio vs 1080p (x100)
  local ratio=$(( pixels * 100 / ref_pixels ))
  local crf="$base_crf"

  # Approx:
  #  - <= 50%  ~ <= 720x576, SD / petites résolutions
  #  - 50–80%  ~ 720p-ish
  #  - 80–130% ~ autour de 1080p
  #  - 130–200% ~ entre 1080p et 1440p / UWQHD
  #  - > 200%  ~ 4K et plus

  if   (( ratio <= 50 )); then
    # très peu de pixels → on baisse un peu le CRF (moins de compression)
    crf=$(( crf - 2 ))
  elif (( ratio <= 80 )); then
    # un peu en dessous de 1080p → petit -1
    crf=$(( crf - 1 ))
  elif (( ratio <= 130 )); then
    # autour de 1080p → on garde le CRF
    crf=$base_crf
  elif (( ratio <= 200 )); then
    # un peu au-dessus (1440p / UWQHD) → +1
    crf=$(( crf + 1 ))
  else
    # 4K et au-delà → +2
    crf=$(( crf + 2 ))
  fi

  # clamp de sécurité
  if (( crf < 18 )); then
    crf=18
  elif (( crf > 40 )); then
    crf=40
  fi

  echo "$crf"
}


############################################
# File scanning
############################################

echo -e "${BOLD}Scanning video files...${RESET}"
echo

found_any=false
count_total=0
count_skipped_meta=0
count_already_av1=0
count_reencoded=0

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
  codec=$(get_video_codec "$file")

  # Nettoyage de sécurité : enlever virgules, espaces, retours chariot, mettre en minuscule
  codec=${codec%%,*}                     # garde tout avant la première virgule
  codec=${codec//$'\r'/}                 # vire éventuels \r
  codec=${codec//[[:space:]]/}           # vire espaces et tabs
  codec=${codec,,}                       # to lower-case (bash 4+)


  if [ -z "$dims" ] || [ -z "$codec" ]; then
    echo -e "[${YELLOW}SKIP${RESET}] Missing metadata (dims/codec): $file"
    ((count_skipped_meta++))
    continue
  fi

  ((count_total++))

  IFS='x' read -r width height <<< "$dims"
  pixels=$(( width * height ))
  label=$(resolution_label_from_height "$height")

  echo -e "${MAGENTA}----------------------------------------${RESET}"
  echo -e "${BOLD}File       :${RESET} $file"
  echo -e "${BOLD}Resolution :${RESET} ${CYAN}${width}x${height}${RESET} (${pixels} pixels) → ${CYAN}$label${RESET}"
  echo -e "${BOLD}Codec      :${RESET} ${CYAN}${codec}${RESET}"

  # Skip if already AV1
  case "$codec" in
    av1|av01)
      echo -e "→ Status    : ${GREEN}ALREADY AV1${RESET} (skipping)"
      ((count_already_av1++))
      continue
      ;;
  esac

  # Guess container format from file extension
guess_container_format() {
  local file="$1"
  local ext="${file##*.}"

  case "${ext,,}" in
    mkv)  echo "matroska" ;;
    mp4|m4v|mov) echo "mp4" ;;
    webm) echo "webm" ;;
    ts)   echo "mpegts" ;;
    avi)  echo "avi" ;;
    *)
      echo ""  # ffmpeg essaiera de deviner, ou échouera
      ;;
  esac
}


  base_crf=$(choose_base_crf "$MEDIA_KIND")
  crf=$(adjust_crf_by_pixels "$base_crf" "$pixels")

  echo -e "→ Status    : ${MAGENTA}RE-ENCODE${RESET} to AV1 (libsvtav1)"
  echo -e "  ${BOLD}Base CRF   :${RESET} ${CYAN}${base_crf}${RESET}"
  echo -e "  ${BOLD}Final CRF  :${RESET} ${GREEN}${crf}${RESET}"

  # Fichier temporaire ignoré par Jellyfin
  tmp_file="${file}.tmp"

    # Deviner le format de conteneur pour ffmpeg
  container_format=$(guess_container_format "$file")

  if ffmpeg -hide_banner -loglevel error -stats -nostdin \
    -y -i "$file" \
    -map 0 \
    -c:v:0 libsvtav1 \
    -c:a copy \
    -c:s copy \
    -fflags +genpts \
    -crf:v:0 "$crf" \
    -preset 6 \
    ${container_format:+-f "$container_format"} \
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

echo -e "Videos analyzed                 : ${CYAN}$count_total${RESET}"
echo -e "Files skipped (missing metadata): ${YELLOW}$count_skipped_meta${RESET}"
echo -e "Already AV1 (skipped)           : ${GREEN}$count_already_av1${RESET}"
echo -e "Files re-encoded to AV1         : ${MAGENTA}$count_reencoded${RESET}"

echo
echo -e "${BOLD}=== End of AV1 / CRF re-encoding ===${RESET}"
exit 0
