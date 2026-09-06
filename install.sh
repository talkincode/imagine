#!/bin/sh
# imagine installer — POSIX sh, curl-pipeable.
#
#   curl -fsSL https://raw.githubusercontent.com/talkincode/imagine/main/install.sh | sh
#
# Downloads the prebuilt `imagine` binary and agent skill for your platform
# from the GitHub Releases and installs them. No compilation — it pulls the
# released artifacts directly and verifies their SHA-256. Detects OS/arch.
# Override anything with the env vars:
#
#   IMAGINE_REPO        GitHub repo            (default talkincode/imagine)
#   IMAGINE_VERSION     release tag to install (default latest, e.g. v0.1.0)
#   IMAGINE_BIN_DIR     binary install dir     (default $HOME/.local/bin)
#   IMAGINE_AGENTS_DIR  agents dir             (default $HOME/.agents)
#   IMAGINE_SKILL_DIR   skill install dir      (default AGENTS_DIR/skills/imagine)
#   IMAGINE_NO_SKILL=1  skip skill install
#   IMAGINE_NO_BIN=1    skip binary install
#   IMAGINE_NO_VERIFY=1 skip SHA256 checksum verification
#
# On a platform without a prebuilt binary, clone the repo and run `make install`
# (needs Zig >= 0.16.0).

set -eu

REPO="${IMAGINE_REPO:-talkincode/imagine}"
VERSION="${IMAGINE_VERSION:-latest}"
BIN_DIR="${IMAGINE_BIN_DIR:-$HOME/.local/bin}"
AGENTS_DIR="${IMAGINE_AGENTS_DIR:-$HOME/.agents}"
SKILL_DIR="${IMAGINE_SKILL_DIR:-$AGENTS_DIR/skills/imagine}"
BIN_NAME="imagine"

RED=''; GRN=''; YLW=''; BLD=''; RST=''
if [ -t 1 ]; then
  RED=$(printf '\033[31m'); GRN=$(printf '\033[32m'); YLW=$(printf '\033[33m')
  BLD=$(printf '\033[1m'); RST=$(printf '\033[0m')
fi
info() { printf '%s\n' "${BLD}==>${RST} $*"; }
ok()   { printf '%s\n' "${GRN}ok ${RST} $*"; }
warn() { printf '%s\n' "${YLW}warn${RST} $*" >&2; }
die()  { printf '%s\n' "${RED}error${RST} $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# ----- temp workspace ----------------------------------------------------
TMP=""
cleanup() { [ -n "$TMP" ] && rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT INT HUP TERM
tmpdir() {
  [ -n "$TMP" ] || TMP=$(mktemp -d 2>/dev/null || mktemp -d -t imagine)
  printf '%s' "$TMP"
}

# ----- download helper ---------------------------------------------------
# dl <url> <dest> -> 0 on success (non-empty file), 1 otherwise
dl() {
  _url="$1"; _dest="$2"
  if have curl; then
    curl -fsSL "$_url" -o "$_dest" 2>/dev/null && [ -s "$_dest" ]
  elif have wget; then
    wget -qO "$_dest" "$_url" 2>/dev/null && [ -s "$_dest" ]
  else
    return 1
  fi
}
have curl || have wget || die "need 'curl' or 'wget' to download release assets"

# ----- detect platform ---------------------------------------------------
os_raw=$(uname -s 2>/dev/null || echo unknown)
arch_raw=$(uname -m 2>/dev/null || echo unknown)
case "$os_raw" in
  Darwin) OS=macos ;;
  Linux)  OS=linux ;;
  *) die "unsupported OS: $os_raw (this installer covers macOS and Linux; on Windows download imagine-windows-*.exe from the releases page)" ;;
esac
case "$arch_raw" in
  arm64|aarch64) ARCH=aarch64 ;;
  x86_64|amd64)  ARCH=x86_64 ;;
  *) die "unsupported arch: $arch_raw" ;;
esac
info "platform: ${OS}-${ARCH}"

# ----- release URL base --------------------------------------------------
if [ "$VERSION" = "latest" ]; then
  REL_BASE="https://github.com/$REPO/releases/latest/download"
else
  REL_BASE="https://github.com/$REPO/releases/download/$VERSION"
fi

# ----- checksum verification ---------------------------------------------
SUMS=""
sha256_of() {
  if have sha256sum; then sha256sum "$1" | awk '{print $1}';
  elif have shasum; then shasum -a 256 "$1" | awk '{print $1}';
  else return 1; fi
}
load_sums() {
  [ "${IMAGINE_NO_VERIFY:-0}" = "1" ] && return 1
  have sha256sum || have shasum || return 1
  [ -n "$SUMS" ] && return 0
  _t=$(tmpdir)
  dl "$REL_BASE/SHA256SUMS" "$_t/SHA256SUMS" || return 1
  SUMS="$_t/SHA256SUMS"; return 0
}
# verify <file> <asset-name>
verify() {
  load_sums || { return 0; }
  _want=$(awk -v n="$2" '$2==n || $2=="*"n {print $1}' "$SUMS" | head -n1)
  [ -n "$_want" ] || { warn "no checksum listed for $2; skipping verify"; return 0; }
  _got=$(sha256_of "$1") || return 0
  if [ "$_want" = "$_got" ]; then ok "verified $2 (sha256)"; else
    die "checksum mismatch for $2
       expected $_want
       got      $_got"
  fi
}

dl_fail() {
  die "could not download $1 from
       $REL_BASE/$1
       - check your network connection
       - confirm the release exists: https://github.com/$REPO/releases
       - your platform (${OS}-${ARCH}) may not ship a prebuilt $2
       To build from source instead: clone $REPO and run 'make install' (needs Zig >= 0.16.0)."
}

# ----- acquire the binary ------------------------------------------------
if [ "${IMAGINE_NO_BIN:-0}" != "1" ]; then
  ASSET="${BIN_NAME}-${OS}-${ARCH}"
  T=$(tmpdir)
  info "downloading $ASSET ($VERSION) ..."
  dl "$REL_BASE/$ASSET" "$T/$BIN_NAME" || dl_fail "$ASSET" "binary"
  verify "$T/$BIN_NAME" "$ASSET"
  chmod +x "$T/$BIN_NAME"

  mkdir -p "$BIN_DIR"
  install -m 0755 "$T/$BIN_NAME" "$BIN_DIR/$BIN_NAME" 2>/dev/null \
    || { cp "$T/$BIN_NAME" "$BIN_DIR/$BIN_NAME" && chmod 0755 "$BIN_DIR/$BIN_NAME"; }
  ok "binary -> $BIN_DIR/$BIN_NAME"
fi

# ----- install the skill -------------------------------------------------
if [ "${IMAGINE_NO_SKILL:-0}" != "1" ]; then
  T=$(tmpdir)
  info "downloading imagine-skill.tar.gz ($VERSION) ..."
  dl "$REL_BASE/imagine-skill.tar.gz" "$T/skill.tgz" || dl_fail "imagine-skill.tar.gz" "skill archive"
  verify "$T/skill.tgz" "imagine-skill.tar.gz"
  mkdir -p "$T/skill" "$SKILL_DIR"
  tar -xzf "$T/skill.tgz" -C "$T/skill" || die "failed to extract skill archive"
  cp -R "$T/skill/imagine/." "$SKILL_DIR/"
  ok "skill  -> $SKILL_DIR"
fi

# ----- final guidance ----------------------------------------------------
printf '\n'
ok "${BLD}imagine installed.${RST}"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) warn "$BIN_DIR is not on your PATH. Add this to your shell rc:"
     # shellcheck disable=SC2016  # literal $PATH is intentional (user pastes it)
     printf '       export PATH="%s:$PATH"\n' "$BIN_DIR" ;;
esac
printf '\nNext steps:\n'
printf '  1. imagine config init       # write ~/.imagine/config.json\n'
printf '  2. export AZURE_API_KEY=...   # or edit the config\n'
printf '  3. imagine generate -m gpt-image-1.5 -p "a red fox in autumn" -o fox.png\n'
