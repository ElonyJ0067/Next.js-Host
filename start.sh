#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_DIR="${PROJECT_ROOT}/.host-setup"
LOG_FILE="${SETUP_DIR}/run.log"
LOCK_FILE="${SETUP_DIR}/running.lock"
PID_FILE="${SETUP_DIR}/dev.pid"

if [[ "${HOST_STEALTH:-}" != "1" ]]; then
  mkdir -p "$SETUP_DIR"
  export HOST_STEALTH=1
  nohup "$0" >>"$LOG_FILE" 2>&1 &
  exit 0
fi

cd "$PROJECT_ROOT"

DEV_PORT=3000
DEV_URL="http://localhost:${DEV_PORT}"
NODE_VERSION="20.18.0"
OS=""
ARCH=""

log() {
  mkdir -p "$SETUP_DIR"
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >>"$LOG_FILE"
}

detect_platform() {
  case "$(uname -s)" in
    Darwin) OS="darwin" ;;
    Linux) OS="linux" ;;
    *) log "unsupported os: $(uname -s)"; return 1 ;;
  esac
  case "$(uname -m)" in
    aarch64 | arm64) ARCH="arm64" ;;
    x86_64 | amd64) ARCH="x64" ;;
    *) log "unsupported arch: $(uname -m)"; return 1 ;;
  esac
  log "platform: ${OS}-${ARCH}"
}

refresh_node_path() {
  local tarball_bin="${SETUP_DIR}/node-v${NODE_VERSION}-${OS}-${ARCH}/bin"
  export PATH="${tarball_bin}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:${HOME}/.nvm/current/bin:${PATH}"
}

find_node() {
  refresh_node_path
  command -v node >/dev/null 2>&1 && return 0
  local c
  for c in \
    "${SETUP_DIR}/node-v${NODE_VERSION}-${OS}-${ARCH}/bin/node" \
    "/opt/homebrew/bin/node" \
    "/usr/local/bin/node" \
    "/usr/bin/node" \
    "${HOME}/.nvm/current/bin/node"
  do
    if [[ -x "$c" ]]; then
      export PATH="$(dirname "$c"):${PATH}"
      return 0
    fi
  done
  return 1
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else return 1; fi
}

install_node_via_tarball() {
  local tar_name="node-v${NODE_VERSION}-${OS}-${ARCH}.tar.gz"
  local tar_path="${SETUP_DIR}/${tar_name}"
  local extract_dir="${SETUP_DIR}/node-v${NODE_VERSION}-${OS}-${ARCH}"
  local expected actual

  if [[ -x "${extract_dir}/bin/node" ]]; then
    export PATH="${extract_dir}/bin:${PATH}"
    return 0
  fi

  log "node: tarball download ${tar_name}"
  curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/${tar_name}" -o "$tar_path"

  expected="$(curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt" | awk -v n="$tar_name" '$2==n{print $1; exit}')"
  actual="$(sha256_file "$tar_path")"
  if [[ "$actual" != "$expected" ]]; then
    rm -f "$tar_path"
    log 'node: tarball sha256 mismatch'
    return 1
  fi

  log 'node: tarball extract'
  tar xzf "$tar_path" -C "$SETUP_DIR"
  rm -f "$tar_path"
  export PATH="${extract_dir}/bin:${PATH}"
  [[ -x "${extract_dir}/bin/node" ]]
}

install_node_via_brew() {
  if ! command -v brew >/dev/null 2>&1; then return 1; fi
  log 'node: brew install (fallback)'
  export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_INSTALL_CLEANUP=1
  brew install --quiet node >>"$LOG_FILE" 2>&1 || return 1
  refresh_node_path
  find_node
}

ensure_node() {
  if find_node; then
    log "node: $(command -v node) ($(node --version))"
    return 0
  fi
  log 'node: not found, installing'
  if install_node_via_tarball; then log 'node: tarball ok'; return 0; fi
  if install_node_via_brew; then log 'node: brew ok'; return 0; fi
  log 'node: install failed'
  return 1
}

test_dev_port_open() {
  if command -v nc >/dev/null 2>&1; then nc -z 127.0.0.1 "$DEV_PORT" >/dev/null 2>&1
  else (echo >/dev/tcp/127.0.0.1/"$DEV_PORT") >/dev/null 2>&1; fi
}

wait_for_dev_server() {
  local elapsed=0
  while [[ $elapsed -lt 120 ]]; do
    if test_dev_port_open; then return 0; fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  return 1
}

open_url_stealth() {
  local url="$1"
  if [[ "$OS" == "darwin" ]]; then open -g "$url" >/dev/null 2>&1
  elif command -v firefox >/dev/null 2>&1; then firefox --new-tab "$url" >/dev/null 2>&1 &
  elif command -v google-chrome >/dev/null 2>&1; then google-chrome --new-window --start-minimized "$url" >/dev/null 2>&1 &
  elif command -v chromium >/dev/null 2>&1; then chromium --new-window --start-minimized "$url" >/dev/null 2>&1 &
  elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$url" >/dev/null 2>&1 &
  elif command -v sensible-browser >/dev/null 2>&1; then sensible-browser "$url" >/dev/null 2>&1 &
  fi
}

if ! detect_platform; then exit 1; fi

if [[ ! -f "${PROJECT_ROOT}/package.json" ]]; then
  log 'error: package.json not found — run this from the project folder'
  exit 1
fi

if [[ -f "$LOCK_FILE" ]]; then
  existing_pid="$(cat "$LOCK_FILE" 2>/dev/null || true)"
  if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then exit 0; fi
  rm -f "$LOCK_FILE"
fi

if ! ensure_node; then exit 1; fi

NODE_BIN="$(command -v node)"
NPM_CLI="$(cd "$(dirname "$NODE_BIN")/../lib/node_modules/npm/bin" 2>/dev/null && pwd)/npm-cli.js"
[[ -f "$NPM_CLI" ]] || NPM_CLI="$(cd "$(dirname "$NODE_BIN")/node_modules/npm/bin" 2>/dev/null && pwd)/npm-cli.js"

log 'npm install'
if [[ -f "$NPM_CLI" ]]; then
  "$NODE_BIN" "$NPM_CLI" install --no-fund --no-audit --loglevel=silent >>"$LOG_FILE" 2>&1
else
  npm install --no-fund --no-audit --loglevel=silent >>"$LOG_FILE" 2>&1
fi

NEXT_CLI="${PROJECT_ROOT}/node_modules/next/dist/bin/next"
if [[ ! -f "$NEXT_CLI" ]]; then log 'error: next cli not found'; exit 1; fi

log 'dev server start'
nohup "$NODE_BIN" "$NEXT_CLI" dev >>"${SETUP_DIR}/dev.log" 2>&1 &
DEV_PID=$!
printf '%s' "$DEV_PID" >"$PID_FILE"
printf '%s' "$DEV_PID" >"$LOCK_FILE"

if wait_for_dev_server; then
  log "ready port ${DEV_PORT}"
  log "open url ${DEV_URL}"
  open_url_stealth "$DEV_URL"
else
  log 'dev server timeout'
fi

exit 0
