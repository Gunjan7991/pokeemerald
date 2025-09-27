#!/usr/bin/env bash
# pm.sh — pokeemerald bootstrap + build helper (macOS)
# Usage:
#   ./pm.sh            # first time or normal incremental build
#   ./pm.sh rebuild    # clean + rebuild
#   ./pm.sh clean      # clean only
#   ./pm.sh tools      # ensure tools only (no build)

set -euo pipefail

### ---- helpers -------------------------------------------------------------

msg() { printf "\033[1;32m==>\033[0m %s\n" "$*"; }
warn(){ printf "\033[1;33m[!]\033[0m %s\n" "$*"; }
err() { printf "\033[1;31m[✗]\033[0m %s\n" "$*"; }
die() { err "$*"; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

# Detect Homebrew prefix (Apple Silicon vs Intel)
BREW_PREFIX=""
if command -v brew >/dev/null 2>&1; then
  BREW_PREFIX="$(brew --prefix)"
  export PATH="$BREW_PREFIX/bin:$PATH"
else
  warn "Homebrew not found. Install from https://brew.sh for an easy setup."
fi

CORES="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
export MAKEFLAGS=${MAKEFLAGS:-"-j${CORES}"}

### ---- checks --------------------------------------------------------------

check_case_sensitivity() {
  # Pokeemerald prefers a case-sensitive filesystem.
  # We'll warn if the current volume is NOT case-sensitive.
  if command -v diskutil >/dev/null 2>&1; then
    local vol
    vol="$(df . | awk 'NR==2{print $1}')"
    if ! diskutil info "$vol" | grep -qi "Case-sensitive: Yes"; then
      warn "Your volume appears to be case-insensitive. Builds may behave oddly."
      warn "Recommended: use an APFS (Case-sensitive) volume/disk image for the repo."
    fi
  fi
}

ensure_xcode_clt() {
  if ! xcode-select -p >/dev/null 2>&1; then
    warn "Xcode Command Line Tools not detected. Running: xcode-select --install"
    xcode-select --install || true
  fi
}

ensure_binutils() {
  # We need ARM EABI binutils + gcc for assembling/ld/cpp steps
  local need_install=0
  for t in arm-none-eabi-as arm-none-eabi-ld arm-none-eabi-gcc; do
    if ! command -v "$t" >/dev/null 2>&1; then
      need_install=1; break
    fi
  done

  if [[ $need_install -eq 1 ]]; then
    if [[ -n "$BREW_PREFIX" ]]; then
      msg "Installing arm-none-eabi toolchain via Homebrew…"
      brew install arm-none-eabi-binutils arm-none-eabi-gcc
    else
      die "Missing ARM EABI toolchain (arm-none-eabi-*). Install via Homebrew then re-run."
    fi
  fi
}

ensure_agbcc() {
  # We support two layouts:
  # 1) ./agbcc exists (preferred in your setup)
  # 2) Not present -> clone here
  if [[ ! -d "$REPO_ROOT/agbcc" ]]; then
    msg "Cloning agbcc into repo…"
    git clone https://github.com/pret/agbcc "$REPO_ROOT/agbcc"
  fi

  pushd "$REPO_ROOT/agbcc" >/dev/null

  # If this looks like a previous/partial build, clean it
  if [[ -d gcc_arm || -f libc.a || -f libgcc.a || -d tools || -d old_agbcc ]]; then
    msg "Cleaning previous agbcc build artifacts…"
    git clean -fX >/dev/null || true
  fi

  msg "Building agbcc…"
  ./build.sh

  msg "Installing agbcc into pokeemerald/tools/agbcc…"
  # Since agbcc/ is inside the repo, install to parent (the repo root)
  ./install.sh ..

  popd >/dev/null

  # Verify install landed
  [[ -x "$REPO_ROOT/tools/agbcc/bin/agbcc" ]] || die "agbcc did not install correctly."
}

### ---- actions -------------------------------------------------------------

do_tools() {
  check_case_sensitivity
  ensure_xcode_clt
  ensure_binutils
  ensure_agbcc
  msg "Tools ready ✔"
}

do_clean() {
  if [[ -f Makefile ]]; then
    msg "Running make clean…"
    make clean || true
  fi
  # Optionally clear build dir fully
  if [[ -d build ]]; then
    msg "Removing build/…"
    rm -rf build
  fi
  msg "Clean complete."
}

do_build() {
  msg "Building pokeemerald (MAKEFLAGS=${MAKEFLAGS})…"
  make
  msg "Build finished."

  if [[ -f pokeemerald.gba ]]; then
    ls -lh pokeemerald.gba pokeemerald.map 2>/dev/null || true
    msg "ROM: $REPO_ROOT/pokeemerald.gba"
  fi
}

### ---- main ---------------------------------------------------------------

case "${1:-}" in
  tools)
    do_tools
    ;;
  clean)
    do_clean
    ;;
  rebuild)
    do_tools
    do_clean
    do_build
    ;;
  ""|build)
    # Default path: ensure tools on first run; otherwise just build incrementally.
    if [[ ! -x "$REPO_ROOT/tools/agbcc/bin/agbcc" ]]; then
      msg "First-time setup detected."
      do_tools
    else
      msg "agbcc already installed — skipping tool bootstrap."
      check_case_sensitivity
      ensure_binutils
    fi
    do_build
    ;;
  *)
    cat <<EOF
Usage: $0 [command]

Commands:
  (none) | build   Ensure tools on first run, then build
  rebuild         Clean + rebuild (also ensures tools)
  clean           Remove build artifacts
  tools           Install/verify toolchain + agbcc only
EOF
    exit 2
    ;;
esac
