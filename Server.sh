#!/usr/bin/env bash
# ============================================================
#  Server.sh  —  EveJS multiplayer host on Linux (VPS / bare metal)
#  Linux counterpart of Server.bat
#
#  Usage:
#    chmod +x Server.sh
#    ./Server.sh                  # auto-detect advertise IP
#    ./Server.sh 1.2.3.4          # public IP or DDNS hostname
#    ./Server.sh --host example.com --token mySecret
#    ./Server.sh --skip-config    # only DB + npm + start (config already done)
#    ./Server.sh --open-firewall  # try ufw allow (needs sudo)
#
#  Ports (TCP): 26000 game, 26001 images, 26002 proxy, 5222 XMPP
# ============================================================
set -euo pipefail

EVEJS_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${EVEJS_REPO_ROOT}"

HOST_ADDRESS="auto"
PLAYER_TOKEN=""
SKIP_CONFIG=0
OPEN_FIREWALL=0
FORCE_DB=0

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage ;;
    --host)
      HOST_ADDRESS="${2:-auto}"
      shift 2
      ;;
    --token)
      PLAYER_TOKEN="${2:-}"
      shift 2
      ;;
    --skip-config)
      SKIP_CONFIG=1
      shift
      ;;
    --open-firewall)
      OPEN_FIREWALL=1
      shift
      ;;
    --force-db)
      FORCE_DB=1
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "[ERROR] Unknown option: $1"
      usage
      ;;
    *)
      # Positional host (same as Server.bat 192.168.1.10)
      HOST_ADDRESS="$1"
      shift
      ;;
  esac
done

echo ""
echo "  ============================================================"
echo "    EveJS - Server (Linux)"
echo "  ============================================================"
echo ""
echo "  Repo:   ${EVEJS_REPO_ROOT}"
echo "  Host:   ${HOST_ADDRESS}"
echo ""
echo "  This will:"
echo "    1. Configure multiplayer advertise/bind (optional)"
echo "    2. Export friend connect bundle"
echo "    3. Optionally open ufw ports"
echo "    4. Ensure local database + npm deps"
echo "    5. Start the game server (foreground)"
echo ""

# --- prerequisites ---
if ! command -v node >/dev/null 2>&1; then
  echo "  [ERROR] Node.js not found. Install Node.js 20+ LTS."
  echo "          e.g. https://nodejs.org or: apt install nodejs npm"
  exit 1
fi
if ! command -v npm >/dev/null 2>&1; then
  echo "  [ERROR] npm not found."
  exit 1
fi
if [[ ! -f "${EVEJS_REPO_ROOT}/server/index.js" ]]; then
  echo "  [ERROR] server/index.js not found under ${EVEJS_REPO_ROOT}"
  exit 1
fi

NODE_VER="$(node -v 2>/dev/null || true)"
echo "  Node:   ${NODE_VER}"
echo ""

# --- multiplayer config (node script; same as Server.bat PowerShell wrapper) ---
if [[ "${SKIP_CONFIG}" -eq 0 ]]; then
  echo "  Configuring multiplayer host: ${HOST_ADDRESS}"
  CFG_ARGS=(node "${EVEJS_REPO_ROOT}/tools/PlayerConnect/configure-multiplayer-host.js" --host "${HOST_ADDRESS}")
  if [[ -n "${PLAYER_TOKEN}" ]]; then
    CFG_ARGS+=(--token "${PLAYER_TOKEN}")
  fi
  "${CFG_ARGS[@]}"
  echo ""
else
  echo "  Skipping multiplayer configure (--skip-config)."
  echo ""
fi

# --- optional firewall ---
open_firewall_ports() {
  local ports=(26000 26001 26002 5222)
  if command -v ufw >/dev/null 2>&1; then
    echo "  Opening ufw TCP ports: ${ports[*]}"
    for p in "${ports[@]}"; do
      sudo ufw allow "${p}/tcp" comment "EveJS" || true
    done
    echo "  (Run: sudo ufw status  — ensure ufw is enabled if you use it)"
  elif command -v firewall-cmd >/dev/null 2>&1; then
    echo "  Opening firewalld TCP ports: ${ports[*]}"
    for p in "${ports[@]}"; do
      sudo firewall-cmd --permanent --add-port="${p}/tcp" || true
    done
    sudo firewall-cmd --reload || true
  else
    echo "  [WARN] No ufw/firewalld found. Open TCP 26000,26001,26002,5222 on your cloud security group."
  fi
  echo ""
}

if [[ "${OPEN_FIREWALL}" -eq 1 ]]; then
  open_firewall_ports
else
  echo "  Firewall: skipped (pass --open-firewall to try ufw/firewalld)."
  echo "  Cloud VPS: also allow TCP 26000 26001 26002 5222 in the provider panel."
  echo ""
fi

# --- legacy migrate ---
if [[ -f "${EVEJS_REPO_ROOT}/server/src/gameStore/migrateLegacyNewDatabase.js" ]]; then
  node "${EVEJS_REPO_ROOT}/server/src/gameStore/migrateLegacyNewDatabase.js" || true
fi

# --- database ---
EVEJS_LOCAL_DATABASE_ROOT="${EVEJS_REPO_ROOT}/_local/gameStore"
export EVEJS_GAMESTORE_DATA_DIR="${EVEJS_LOCAL_DATABASE_ROOT}/data"
MANIFEST="${EVEJS_LOCAL_DATABASE_ROOT}/manifest.json"
STATIONS="${EVEJS_GAMESTORE_DATA_DIR}/stations/data.json"

ensure_local_database() {
  if [[ -f "${MANIFEST}" && -f "${STATIONS}" && "${FORCE_DB}" -ne 1 ]]; then
    local sz
    sz="$(wc -c < "${STATIONS}" | tr -d ' ')"
    if [[ "${sz}" -gt 1024 ]]; then
      echo "  Local database ready: ${EVEJS_GAMESTORE_DATA_DIR}"
      echo "  stations/data.json: ${sz} bytes"
      echo ""
      return 0
    fi
  fi

  local creator="${EVEJS_REPO_ROOT}/tools/DatabaseCreator/CreateDatabase.sh"
  if [[ ! -x "${creator}" && -f "${creator}" ]]; then
    chmod +x "${creator}" || true
  fi
  if [[ ! -f "${creator}" ]]; then
    echo "  [ERROR] Database missing and CreateDatabase.sh not found:"
    echo "          ${creator}"
    exit 1
  fi

  echo "  Local database not found or incomplete."
  echo "  Running CreateDatabase.sh (download SDE + generate — may take a long time)..."
  echo ""
  if [[ "${FORCE_DB}" -eq 1 ]]; then
    bash "${creator}" --force
  else
    bash "${creator}"
  fi
  echo ""
}

ensure_local_database

# --- npm deps ---
if [[ ! -f "${EVEJS_REPO_ROOT}/server/node_modules/express/package.json" ]]; then
  echo "  Installing server dependencies (npm ci)..."
  echo "  Note: better-sqlite3 compiles native code — need build-essential / python3."
  echo ""
  (
    cd "${EVEJS_REPO_ROOT}/server"
    npm ci
  )
  echo ""
  echo "  Dependencies installed."
  echo ""
else
  echo "  Server node_modules present."
  echo ""
fi

# --- env (critical — same as Server.bat) ---
export EVEJS_PROXY_LOCAL_INTERCEPT=1
export EVEJS_GAMESTORE_DATA_DIR
mkdir -p "${EVEJS_REPO_ROOT}/server/logs/node-reports"

BUNDLE="${EVEJS_REPO_ROOT}/_local/player-connect-bundle"

echo "  ============================================================"
echo "    Server is starting. Friends use the connect bundle:"
echo "      ${BUNDLE}"
echo ""
echo "    Ports: 26000  26001  26002  5222"
echo "    EVEJS_GAMESTORE_DATA_DIR=${EVEJS_GAMESTORE_DATA_DIR}"
echo ""
echo "    Expect log line:  [SpaceWorld] Loaded ... stations  (stations >> 0)"
echo "    Press Ctrl+C to stop."
echo "  ============================================================"
echo ""

cd "${EVEJS_REPO_ROOT}/server"
exec npm start
