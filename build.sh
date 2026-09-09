#!/usr/bin/env bash
# ============================================================================
#  build.sh - Build BrowserOS neo from source on macOS (arm64 / x64)
#
#  "BrowserOS neo" is the product id "browserclaw" in bos_build
#  (see packages/browseros/bos_build/products/browserclaw/product.py).
#
#  What it does:
#    1. Prepares a Chromium checkout at the pinned version
#       (packages/browseros/CHROMIUM_VERSION) under $CHROMIUM_ROOT.
#       Clones depot_tools if missing, fetches the pinned tag shallowly,
#       and runs gclient sync. First run downloads ~100 GB and takes hours;
#       reruns are incremental (ninja resumes where it left off).
#    2. Prepares the neo agent resources: by default (AGENT_MODE=source)
#       builds claw-server-rust with cargo and claw-onboard with bun from
#       this checkout, staging them where the R2-based download_resources
#       step would put them. AGENT_MODE=published instead downloads the
#       released bundles from the public CDN (cdn.browseros.com). Either way
#       that step is skipped afterwards.
#    3. Runs the bos_build pipeline: applies BrowserOS patches, compiles
#       with autoninja, builds an unsigned .app, and packages it into a DMG
#       at packages/browseros/releases/<version>/.
#
#  One-time prerequisites:
#    - uv (https://docs.astral.sh/uv/)
#    - git
#    - Full Xcode (not just the Command Line Tools) with a recent macOS SDK;
#      Chromium's macOS build needs the complete toolchain.
#    - Rust and Bun are installed automatically (user-local, no sudo) when
#      AGENT_MODE=source; not needed for AGENT_MODE=published.
#    - ~100 GB free disk on the volume holding $CHROMIUM_ROOT, 16+ GB RAM.
#
#  Overrides (export before calling, e.g.:  PRESET=debug ./build.sh):
#    PRESET         release | debug          default: release
#    PRODUCT        browserclaw | browseros  default: browserclaw (= neo)
#    ARCH           arm64 | x64              default: arm64 (Apple Silicon;
#                   matches the CI nightly builder)
#    PROVISION      shallow | full           default: shallow (self-contained).
#                   Use full only if $CHROMIUM_SRC is already a complete
#                   Chromium checkout you maintain yourself.
#    RESOURCE_MODE  published | source       default: published (downloads
#                   released components from the public CDN; no secrets)
#    AGENT_MODE     source | published   default: source (builds the neo agent
#                   components claw-server-rust + claw-onboard from this
#                   checkout with cargo/bun, auto-installing Rust and Bun if
#                   missing). published downloads them from cdn.browseros.com.
#    SIGN           yes | no                 default: no (yes needs
#                   MACOS_CERTIFICATE_NAME / notarization vars in
#                   packages/browseros/.env, copied from .env.example)
#    UPLOAD         yes | no                 default: no (yes needs R2_*)
#    CHROMIUM_ROOT  checkout root            default: $HOME/chromium
#                   (the src tree lives at $CHROMIUM_ROOT/src)
# ============================================================================

set -euo pipefail

on_error() {
  echo
  echo "[build] FAILED. See the error above. Rerun build.sh to resume; ninja picks up where it stopped."
  exit 1
}
trap on_error ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PRESET="${PRESET:-release}"
PRODUCT="${PRODUCT:-browserclaw}"
ARCH="${ARCH:-arm64}"
PROVISION="${PROVISION:-shallow}"
RESOURCE_MODE="${RESOURCE_MODE:-published}"
AGENT_MODE="${AGENT_MODE:-source}"
SIGN="${SIGN:-no}"
UPLOAD="${UPLOAD:-no}"
CHROMIUM_ROOT="${CHROMIUM_ROOT:-$HOME/chromium}"
CHROMIUM_SRC="$CHROMIUM_ROOT/src"

# Target id used by bos_build (see bos_build/release/server_resources.py) and
# the Rust triple cargo builds for.
case "$ARCH" in
  arm64) TARGET="darwin-arm64"; TRIPLE="aarch64-apple-darwin" ;;
  x64)   TARGET="darwin-x64";   TRIPLE="x86_64-apple-darwin" ;;
  *) echo "[build] ERROR: ARCH must be arm64 or x64 (got '$ARCH')"; exit 1 ;;
esac

if [ "$(uname)" != "Darwin" ]; then
  echo "[build] ERROR: build.sh is for macOS; on Windows use build.bat."
  exit 1
fi

echo
echo === BrowserOS neo build ===
echo   preset        = $PRESET
echo   product       = $PRODUCT
echo   arch          = $ARCH
echo   provision     = $PROVISION
echo   resource mode = $RESOURCE_MODE
echo   agent mode    = $AGENT_MODE
echo   sign / upload = $SIGN / $UPLOAD
echo   chromium root = $CHROMIUM_ROOT
echo

# --- Preflight -------------------------------------------------------------
command -v uv >/dev/null 2>&1 || { echo "[build] ERROR: uv not found on PATH. Install it: https://docs.astral.sh/uv/"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "[build] ERROR: git not found on PATH."; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "[build] ERROR: curl not found on PATH. It ships with macOS."; exit 1; }

# Chromium's macOS build needs the full Xcode toolchain, not just CLT.
if ! xcrun --find cc >/dev/null 2>&1; then
  echo "[build] ERROR: no C compiler found (xcrun --find cc failed). Install Xcode from the App Store and run 'sudo xcode-select -s /Applications/Xcode.app'."
  exit 1
fi
if [ ! -d /Applications/Xcode.app ]; then
  echo "[build] WARNING: full Xcode not found at /Applications/Xcode.app. A Chromium build needs it; the Command Line Tools alone are not enough."
fi

# Warn if the volume holding the checkout is close to full; Chromium needs ~100 GB.
mkdir -p "$CHROMIUM_ROOT"
FREE_KB="$(df -k "$CHROMIUM_ROOT" | awk 'NR==2 {print $4}')"
if [ "${FREE_KB:-0}" -lt 104857600 ]; then
  echo "[build] WARNING: less than 100 GB free on the volume holding $CHROMIUM_ROOT. A Chromium build needs ~100 GB."
fi

# --- depot_tools -----------------------------------------------------------
# The compile step calls gn / autoninja bare, so depot_tools must be on PATH.
# Clone it if missing (the pipeline's source_checkout step reuses this clone;
# it is idempotent).
if [ ! -d "$CHROMIUM_ROOT/depot_tools/.git" ]; then
  echo "[build] Cloning depot_tools into $CHROMIUM_ROOT/depot_tools ..."
  git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "$CHROMIUM_ROOT/depot_tools"
fi
export PATH="$CHROMIUM_ROOT/depot_tools:$PATH"

# --- Build -----------------------------------------------------------------
cd "$SCRIPT_DIR/packages/browseros"

echo "[build] Syncing python environment (uv sync)..."
uv sync

# --- Agent resources --------------------------------------------------------
# AGENT_MODE=source builds the neo agent components from this checkout and
# stages them where download_resources would put them:
#   - claw-server-rust via cargo (the same command bos_build's
#     ServerResourceBuilder uses for darwin-<arch>)
#   - claw-onboard via its bun build script (--no-upload, no R2 credentials)
# AGENT_MODE=published keeps the old behavior: fetch the released bundles
# from cdn.browseros.com. Only product browserclaw supports source mode;
# other products always use published resources.

AGENT_ROOT="$SCRIPT_DIR/packages/browseros-agent"
SERVER_DEST="resources/binaries/browseros_claw_server_rust/$TARGET"
ONBOARD_DEST="resources/binaries/browseros_onboarding"

if [ "$PRODUCT" != "browserclaw" ]; then
  echo "[build] NOTE: AGENT_MODE=$AGENT_MODE is only supported for product browserclaw; staging published resources instead."
  AGENT_MODE=published
fi

if [ "$AGENT_MODE" = "published" ]; then
  # The download_resources step fetches these bundles via the R2 S3 API, which
  # needs credentials. The identical objects are served anonymously at
  # cdn.browseros.com (same bucket's public CDN), so we stage them here and
  # skip that step. Keys/destinations mirror bos_build/config/download_resources.yaml.
  STAGE_DIR="${TMPDIR:-/tmp}/browseros-cdn-staging"
  mkdir -p "$STAGE_DIR"

  if [ "$PRODUCT" = "browserclaw" ]; then
    SERVER_URL="https://cdn.browseros.com/claw-server-rust/prod-resources/latest/browseros-claw-server-rust-resources-$TARGET.zip"
    ONBOARD_URL="https://cdn.browseros.com/claw-onboard/prod-resources/latest/browseros-claw-onboard-resources.zip"
  else
    SERVER_URL="https://cdn.browseros.com/artifacts/server/latest/browseros-server-resources-$TARGET.zip"
    ONBOARD_URL="https://cdn.browseros.com/app-onboard/prod-resources/latest/browseros-app-onboard-resources.zip"
    SERVER_DEST="resources/binaries/browseros_server/$TARGET"
  fi

  echo "[build] Staging published resources from cdn.browseros.com (no R2 credentials needed)..."
  curl -fL --retry 3 --connect-timeout 20 -o "$STAGE_DIR/server.zip" "$SERVER_URL"
  curl -fL --retry 3 --connect-timeout 20 -o "$STAGE_DIR/onboard.zip" "$ONBOARD_URL"

  uv run python tools/stage_cdn_resources.py --zip "$STAGE_DIR/server.zip" --dest "$SERVER_DEST"
  uv run python tools/stage_cdn_resources.py --zip "$STAGE_DIR/onboard.zip" --dest "$ONBOARD_DEST"
else
  # --- source mode: toolchain (user-local installs, no sudo) ---------------
  CARGO_BIN="$HOME/.cargo/bin"
  if ! command -v cargo >/dev/null 2>&1 && [ -x "$CARGO_BIN/cargo" ]; then
    export PATH="$CARGO_BIN:$PATH"
  fi
  if ! command -v cargo >/dev/null 2>&1; then
    echo "[build] Rust not found; installing rustup + stable toolchain ..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
    export PATH="$CARGO_BIN:$PATH"
  fi
  command -v cargo >/dev/null 2>&1 || { echo "[build] ERROR: Rust install failed. Install manually: https://rustup.rs"; exit 1; }
  if ! rustup target list --installed | grep -qx "$TRIPLE"; then
    echo "[build] Adding Rust target $TRIPLE ..."
    rustup target add "$TRIPLE"
  fi

  BUN_BIN="$HOME/.bun/bin"
  if ! command -v bun >/dev/null 2>&1 && [ -x "$BUN_BIN/bun" ]; then
    export PATH="$BUN_BIN:$PATH"
  fi
  if ! command -v bun >/dev/null 2>&1; then
    echo "[build] Bun not found; installing ..."
    curl -fsSL https://bun.sh/install | bash
    export PATH="$BUN_BIN:$PATH"
  fi
  command -v bun >/dev/null 2>&1 || { echo "[build] ERROR: Bun install failed. Install manually: https://bun.sh"; exit 1; }

  # The agent asset packager shells out to the zip CLI; macOS ships it at
  # /usr/bin/zip, so no shim is needed (Windows gets one via tools/zip-shim).
  command -v zip >/dev/null 2>&1 || echo "[build] WARNING: zip not found on PATH; packaging agent resources may fail."

  if [ -z "${CLAW_POSTHOG_KEY:-}" ]; then
    export CLAW_POSTHOG_KEY="phc_browseros_ci"
    echo "[build] NOTE: CLAW_POSTHOG_KEY not set; inlining the CI placeholder. Set it before running build.sh to inline a real key."
  fi

  if [ ! -d "$AGENT_ROOT/node_modules" ]; then
    echo "[build] Installing agent workspace dependencies via bun install ..."
    (cd "$AGENT_ROOT" && bun install)
  fi

  echo "[build] Building claw-server-rust from source (cargo; first run ~4 min) ..."
  CARGO_TARGET_DIR="$AGENT_ROOT/target" cargo build --release --locked \
    -p claw-server-rust --bin browseros-claw-server-rs --target "$TRIPLE" \
    --manifest-path "$AGENT_ROOT/Cargo.toml"

  SERVER_VERSION="$(awk -F'"' '/^version = /{print $2; exit}' "$AGENT_ROOT/apps/claw-server-rust/Cargo.toml")"
  [ -n "$SERVER_VERSION" ] || { echo "[build] ERROR: could not read claw-server-rust version from Cargo.toml"; exit 1; }

  SOURCE_SHA="$(git rev-parse HEAD)"

  uv run python tools/stage_local_server.py \
    --exe "$AGENT_ROOT/target/$TRIPLE/release/browseros-claw-server-rs" \
    --skill "$AGENT_ROOT/resources/skills/browserclaw/SKILL.md" \
    --dest "$SERVER_DEST" \
    --version "$SERVER_VERSION" \
    --target "$TARGET" \
    --source-sha "$SOURCE_SHA" \
    --zip-out "$AGENT_ROOT/dist/prod/claw-server-rust/browseros-claw-server-rust-resources-$TARGET.zip"

  echo "[build] Building claw-onboard from source (bun) ..."
  (cd "$AGENT_ROOT" && NODE_ENV=production bun scripts/build/claw-onboard.ts --no-upload)

  uv run python tools/stage_cdn_resources.py \
    --zip "$AGENT_ROOT/dist/prod/claw-onboard/browseros-claw-onboard-resources.zip" \
    --dest "$ONBOARD_DEST"
fi

# TARGET is only a local helper for the CDN URLs / staging above; Chromium's
# Rust bindgen step refuses to run when TARGET is in the environment, so clear it.
unset TARGET

SIGN_FLAG="--no-sign"
[ "$SIGN" = "yes" ] && SIGN_FLAG="--sign"
UPLOAD_FLAG="--no-upload"
[ "$UPLOAD" = "yes" ] && UPLOAD_FLAG="--upload"

echo
echo "[build] Running: uv run browseros build --preset $PRESET --product $PRODUCT \
  --arch $ARCH --resource-mode $RESOURCE_MODE $SIGN_FLAG $UPLOAD_FLAG --provision $PROVISION --chromium-src \"$CHROMIUM_SRC\" --skip download_resources"
echo

uv run browseros build --preset "$PRESET" --product "$PRODUCT" --arch "$ARCH" \
  --resource-mode "$RESOURCE_MODE" $SIGN_FLAG $UPLOAD_FLAG \
  --provision "$PROVISION" --chromium-src "$CHROMIUM_SRC" --skip download_resources

# --- Result ------------------------------------------------------------------
# Mirror bos_build/lib/versions.py load_semantic_version: PATCH only when
# non-zero, a zero BUILD still renders as ".0".
BV_MAJ=0 BV_MIN=0 BV_BLD=0 BV_PAT=0
while IFS='=' read -r k v; do
  case "$k" in
    BROWSEROS_MAJOR) BV_MAJ="$v" ;;
    BROWSEROS_MINOR) BV_MIN="$v" ;;
    BROWSEROS_BUILD) BV_BLD="$v" ;;
    BROWSEROS_PATCH) BV_PAT="$v" ;;
  esac
done < resources/BROWSEROS_VERSION
if [ "$BV_PAT" != "0" ]; then
  BVER="$BV_MAJ.$BV_MIN.$BV_BLD.$BV_PAT"
elif [ "$BV_BLD" != "0" ]; then
  BVER="$BV_MAJ.$BV_MIN.$BV_BLD"
else
  BVER="$BV_MAJ.$BV_MIN.0"
fi

if [ "$PRODUCT" = "browserclaw" ]; then
  ART_PREFIX="BrowserOS_neo"
else
  ART_PREFIX="BrowserOS"
fi
DIST_DIR="$SCRIPT_DIR/packages/browseros/releases/$BVER"
DMG_NAME="$ART_PREFIX_v$BVER_$ARCH.dmg"

echo
echo === Build complete ===
if [ -f "$DIST_DIR/$DMG_NAME" ]; then
  echo "   DMG (install this): $DIST_DIR/$DMG_NAME"
else
  echo "   WARNING: expected DMG not found: $DIST_DIR/$DMG_NAME"
fi
for app in "$CHROMIUM_SRC"/out/Default_"$PRODUCT"_*/*.app; do
  if [ -d "$app" ]; then
    echo "   App bundle (no install needed): $app"
  fi
done
echo "   Dist dir: $DIST_DIR"
