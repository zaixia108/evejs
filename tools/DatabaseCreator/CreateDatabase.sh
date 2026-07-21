#!/usr/bin/env bash
# EvEJS local static database generator (Linux / macOS).
# Equivalent to CreateDatabase.bat
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVEJS_REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SDE_BUILD="${SDE_BUILD:-3396210}"
SDE_URL="${SDE_URL:-https://developers.eveonline.com/static-data/tranquility/eve-online-static-data-${SDE_BUILD}-jsonl.zip}"
LOCAL_ROOT="${EVEJS_REPO_ROOT}/_local"
DOWNLOAD_DIR="${LOCAL_ROOT}/downloads/sde"
SDE_ZIP="${DOWNLOAD_DIR}/eve-online-static-data-${SDE_BUILD}-jsonl.zip"
SDE_DIR="${LOCAL_ROOT}/sde/eve-online-static-data-${SDE_BUILD}-jsonl"
DATA_DIR="${LOCAL_ROOT}/gameStore/data"
MANIFEST="${LOCAL_ROOT}/gameStore/manifest.json"

FORCE=0
for arg in "$@"; do
  case "$arg" in
    /force|--force|-f) FORCE=1 ;;
    -h|--help)
      echo "Usage: $0 [--force]"
      echo "  Downloads CCP SDE JSONL and generates _local/gameStore/data"
      exit 0
      ;;
  esac
done

echo ""
echo "  ============================================================"
echo "    EvEJS Local Database Creator (Linux)"
echo "  ============================================================"
echo ""
echo "  Build:  ${SDE_BUILD}"
echo "  Output: ${DATA_DIR}"
echo ""

if ! command -v node >/dev/null 2>&1; then
  echo "  [ERROR] Node.js is required (LTS 20+ recommended)."
  exit 1
fi

if [[ -f "${MANIFEST}" && "${FORCE}" -ne 1 ]]; then
  echo "  Existing generated database found:"
  echo "    ${MANIFEST}"
  echo "  Keeping it. Re-run with --force to rebuild."
  exit 0
fi

mkdir -p "${DOWNLOAD_DIR}"

if [[ ! -f "${SDE_ZIP}" ]]; then
  echo "  Downloading CCP public SDE JSONL..."
  if command -v curl >/dev/null 2>&1; then
    curl -fL --progress-bar -o "${SDE_ZIP}" "${SDE_URL}"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "${SDE_ZIP}" "${SDE_URL}"
  else
    echo "  [ERROR] Need curl or wget to download the SDE."
    exit 1
  fi
else
  echo "  Using cached SDE zip."
fi

if [[ ! -f "${SDE_DIR}/_sde.jsonl" ]]; then
  echo "  Extracting SDE zip..."
  rm -rf "${SDE_DIR}"
  mkdir -p "${SDE_DIR}"
  if command -v unzip >/dev/null 2>&1; then
    unzip -q -o "${SDE_ZIP}" -d "${SDE_DIR}"
  else
    echo "  [ERROR] unzip is required (e.g. apt install unzip)."
    exit 1
  fi
else
  echo "  Using extracted SDE directory."
fi

echo "  Generating EvEJS local database (this can take several minutes)..."
node --max-old-space-size=8192 \
  "${SCRIPT_DIR}/database-creator.js" \
  --sde-dir "${SDE_DIR}" \
  --out "${DATA_DIR}" \
  --build "${SDE_BUILD}" \
  --sde-url "${SDE_URL}" \
  --force

echo ""
echo "  Database generation complete."
echo "  Manifest: ${MANIFEST}"
echo "  Data dir: ${DATA_DIR}"
echo ""
