#!/bin/bash
#
# CI Release Script for Mainline
#
# Runs in GitHub Actions after the version tag has been created.
# Builds Mainline.app, zips it, creates a GitHub release, and updates the
# Homebrew tap (mthines/homebrew-mainline).
#
# Required env:
#   RELEASE_VERSION     - e.g. v1.0.0 or v1.0.0-beta.42.1
#   IS_BETA             - "true" | "false"
#   GITHUB_TOKEN        - For `gh release create`
#   HOMEBREW_TAP_TOKEN  - PAT with repo scope on mthines/homebrew-mainline
#   DASH0_AUTH_TOKEN    - Embedded into the Release build (optional but warns if missing)
#
# Optional env:
#   PR_NUMBER                    - Required when IS_BETA=true
#   DRY_RUN                      - "true" to skip publishing steps
#   OTEL_EXPORTER_OTLP_ENDPOINT  - Passed to xcodebuild for telemetry (repository variable)
#   MACOS_CERTIFICATE_P12_BASE64 - Base64-encoded Developer ID cert (optional)
#   MACOS_CERTIFICATE_PASSWORD   - Password for the P12 (optional)
#   NOTARY_KEY_P8_BASE64         - Base64-encoded notary key (optional)
#   NOTARY_KEY_ID                - Notary key ID (optional)
#   NOTARY_ISSUER_ID             - Notary issuer ID (optional)
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}i${NC} $1"; }
log_success() { echo -e "${GREEN}ok${NC} $1"; }
log_warning() { echo -e "${YELLOW}warn${NC} $1"; }
log_error() { echo -e "${RED}err${NC} $1" >&2; exit 1; }

if [ -z "${CI:-}" ]; then
  log_error "This script is designed to run in CI only. For local releases use: pnpm release"
fi

VERSION="${RELEASE_VERSION#v}"
TAG="v${VERSION}"

PROJECT_NAME="Mainline"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
XCODEPROJ="$PROJECT_DIR/Mainline.xcodeproj"

cd "$PROJECT_DIR"

log_info "CI release ${TAG} (beta=${IS_BETA})"

if [ -z "${DASH0_AUTH_TOKEN:-}" ]; then
  log_warning "DASH0_AUTH_TOKEN not set — telemetry token will not be embedded"
fi

if [ -z "${OTEL_EXPORTER_OTLP_ENDPOINT:-}" ]; then
  log_warning "OTEL_EXPORTER_OTLP_ENDPOINT not set — telemetry endpoint will be empty"
fi

# =============================================================================
# Build Release .app
# =============================================================================
log_info "Building Release configuration..."
mkdir -p "$BUILD_DIR"

xcodebuild -project "$XCODEPROJ" \
  -scheme "$PROJECT_NAME" \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  clean build \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  DASH0_AUTH_TOKEN="${DASH0_AUTH_TOKEN:-}" \
  OTEL_EXPORTER_OTLP_ENDPOINT="${OTEL_EXPORTER_OTLP_ENDPOINT:-}" \
  | tail -20

APP_PATH="$BUILD_DIR/DerivedData/Build/Products/Release/${PROJECT_NAME}.app"
BINARY="$APP_PATH/Contents/MacOS/${PROJECT_NAME}"

if [ ! -f "$BINARY" ]; then
  log_error "Binary not found at $BINARY — build produced an empty app bundle"
fi

ARCH_INFO=$(lipo -info "$BINARY" 2>/dev/null | sed 's/.*: //' || echo "unknown")
log_success "Build OK ($ARCH_INFO)"

# =============================================================================
# Developer ID signing (OPT-IN — only runs when the signing secrets are present).
#
# Without MACOS_CERTIFICATE_P12_BASE64 the app stays unsigned (CODE_SIGNING_ALLOWED=NO
# above), so this can never break an existing release; it only *upgrades* the
# release when configured. See docs/release.md for the one-time setup.
# =============================================================================
SIGNED="false"
if [ -n "${MACOS_CERTIFICATE_P12_BASE64:-}" ] && [ -n "${MACOS_CERTIFICATE_PASSWORD:-}" ]; then
  log_info "Developer ID signing enabled — importing certificate into a temp keychain..."
  KEYCHAIN="$BUILD_DIR/mainline-signing.keychain-db"
  KEYCHAIN_PW="$(uuidgen)"
  CERT_P12="$BUILD_DIR/developer_id.p12"
  echo "$MACOS_CERTIFICATE_P12_BASE64" | base64 --decode > "$CERT_P12"

  security create-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN"
  security set-keychain-settings -lut 21600 "$KEYCHAIN"
  security unlock-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN"
  security import "$CERT_P12" -k "$KEYCHAIN" -P "$MACOS_CERTIFICATE_PASSWORD" \
    -T /usr/bin/codesign -T /usr/bin/security
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PW" "$KEYCHAIN" >/dev/null
  # Put our keychain first in the search list so codesign resolves the identity.
  # shellcheck disable=SC2046
  security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | sed s/\"//g)
  rm -f "$CERT_P12"

  IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN" \
    | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
  [ -n "$IDENTITY" ] || log_error "No 'Developer ID Application' identity in the imported certificate."
  log_success "Signing identity: $IDENTITY"

  APP_ENTITLEMENTS="$PROJECT_DIR/Mainline/Mainline/Mainline.entitlements"

  # Sign inside-out (nested code first, then the app). Hardened runtime
  # (--options runtime) + a secure --timestamp are required for notarization.
  if [ -d "$APP_PATH/Contents/Frameworks" ]; then
    while IFS= read -r -d '' item; do
      codesign --force --timestamp --options runtime --keychain "$KEYCHAIN" \
        --sign "$IDENTITY" "$item"
    done < <(find "$APP_PATH/Contents/Frameworks" -mindepth 1 -maxdepth 1 -print0)
  fi
  codesign --force --timestamp --options runtime --keychain "$KEYCHAIN" \
    --entitlements "$APP_ENTITLEMENTS" --sign "$IDENTITY" "$APP_PATH"

  codesign --verify --deep --strict --verbose=2 "$APP_PATH"
  log_success "Signed with Developer ID"
  SIGNED="true"
else
  log_warning "MACOS_CERTIFICATE_* not set — building UNSIGNED. See docs/release.md for signing setup."
fi

# =============================================================================
# Zip
# =============================================================================
ZIP_NAME="${PROJECT_NAME}-${TAG}-macOS.zip"
ZIP_PATH="$BUILD_DIR/$ZIP_NAME"

ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

# Verify zip can be extracted and contains binary
VERIFY_DIR=$(mktemp -d)
ditto -x -k "$ZIP_PATH" "$VERIFY_DIR"
if [ ! -f "$VERIFY_DIR/${PROJECT_NAME}.app/Contents/MacOS/${PROJECT_NAME}" ]; then
  rm -rf "$VERIFY_DIR"
  log_error "Zip verification failed — extracted app has no binary"
fi
rm -rf "$VERIFY_DIR"

# =============================================================================
# Notarize + staple (only when signed AND notary creds present). Stapling embeds
# the notarization ticket so Gatekeeper accepts the app offline; we then re-zip
# so the distributed archive (and its sha256) covers the stapled bundle.
# =============================================================================
if [ "$SIGNED" = "true" ] && [ -n "${NOTARY_KEY_P8_BASE64:-}" ] \
   && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER_ID:-}" ]; then
  log_info "Notarizing with Apple (usually a few minutes; capped at 30m)..."
  NOTARY_KEY="$BUILD_DIR/notary_key.p8"
  echo "$NOTARY_KEY_P8_BASE64" | base64 --decode > "$NOTARY_KEY"
  # --timeout bounds the wait so an Apple Notary Service backlog fails the step
  # fast instead of blocking until GitHub's 6h job cap (macOS runners bill 10x).
  xcrun notarytool submit "$ZIP_PATH" \
    --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" \
    --wait --timeout 30m
  rm -f "$NOTARY_KEY"
  xcrun stapler staple "$APP_PATH"
  xcrun stapler validate "$APP_PATH"
  log_success "Notarized + stapled"
  # Re-zip so the published archive contains the stapled ticket.
  rm -f "$ZIP_PATH"
  ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
elif [ "$SIGNED" = "true" ]; then
  log_warning "Signed but NOTARY_* not set — skipping notarization. Gatekeeper will still quarantine the app on download."
fi

ZIP_SHA=$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')
ZIP_SIZE=$(du -h "$ZIP_PATH" | cut -f1)
log_success "Created $ZIP_NAME ($ZIP_SIZE, sha256=${ZIP_SHA:0:12}...)"

# Expose for downstream workflow steps
if [ -n "${GITHUB_ENV:-}" ]; then
  echo "ZIP_SHA=$ZIP_SHA" >> "$GITHUB_ENV"
  echo "ZIP_PATH=$ZIP_PATH" >> "$GITHUB_ENV"
fi

# =============================================================================
# Changelog
# =============================================================================
PREVIOUS_TAG=$(git tag -l "v*" --sort=-version:refname \
  | grep -E "^v[0-9]" \
  | grep -v "beta" \
  | grep -v "^${TAG}$" \
  | head -n 1 || echo "")

if [ -z "$PREVIOUS_TAG" ]; then
  COMMIT_RANGE="HEAD"
else
  COMMIT_RANGE="${PREVIOUS_TAG}..${TAG}"
fi

# Categorize commits into features / fixes / other
FEATURES=$(git log "$COMMIT_RANGE" --pretty=format:"%s|%h" --no-merges 2>/dev/null | grep -E "^feat(\(.+\))?: " || true)
FIXES=$(git log "$COMMIT_RANGE" --pretty=format:"%s|%h" --no-merges 2>/dev/null | grep -E "^fix(\(.+\))?: " || true)
OTHERS=$(git log "$COMMIT_RANGE" --pretty=format:"%s|%h" --no-merges 2>/dev/null \
  | grep -vE "^(feat|fix|chore|ci|docs|style|refactor|test)(\(.+\))?: " || true)

CHANGELOG="## What's Changed in ${TAG}"$'\n\n'

if [ -n "$FEATURES" ]; then
  CHANGELOG+="### Features"$'\n'
  while IFS='|' read -r message hash; do
    [ -z "$message" ] && continue
    clean=$(echo "$message" | sed -E 's/^feat(\(.+\))?: //')
    CHANGELOG+="- ${clean} (\`${hash}\`)"$'\n'
  done <<< "$FEATURES"
  CHANGELOG+=$'\n'
fi

if [ -n "$FIXES" ]; then
  CHANGELOG+="### Bug Fixes"$'\n'
  while IFS='|' read -r message hash; do
    [ -z "$message" ] && continue
    clean=$(echo "$message" | sed -E 's/^fix(\(.+\))?: //')
    CHANGELOG+="- ${clean} (\`${hash}\`)"$'\n'
  done <<< "$FIXES"
  CHANGELOG+=$'\n'
fi

if [ -n "$OTHERS" ]; then
  CHANGELOG+="### Other Changes"$'\n'
  while IFS='|' read -r message hash; do
    [ -z "$message" ] && continue
    CHANGELOG+="- ${message} (\`${hash}\`)"$'\n'
  done <<< "$OTHERS"
  CHANGELOG+=$'\n'
fi

CHANGELOG+=$'\n---\n\n### Installation\n\n'

if [ "$IS_BETA" = "true" ]; then
  CHANGELOG+='**Via Homebrew (beta tap):**'$'\n'
  CHANGELOG+='```bash'$'\n'
  CHANGELOG+='brew tap mthines/mainline'$'\n'
  CHANGELOG+='brew install --cask --force mthines/mainline/mainline-beta              # latest beta'$'\n'
  CHANGELOG+="brew install --cask --force mthines/mainline/mainline-beta@${VERSION}    # this exact version"$'\n'
  CHANGELOG+='```'$'\n'
  CHANGELOG+=$'\n'
  # shellcheck disable=SC2016  # backticks are Markdown formatting, not shell expansion
  CHANGELOG+='> `--force` lets Homebrew overwrite a stable Mainline.app already installed by the `mainline` cask.'$'\n'
else
  CHANGELOG+='**Via Homebrew (recommended):**'$'\n'
  CHANGELOG+='```bash'$'\n'
  CHANGELOG+='brew tap mthines/mainline'$'\n'
  CHANGELOG+='brew install --cask mainline'$'\n'
  CHANGELOG+='```'$'\n'
fi

CHANGELOG+=$'\n'
CHANGELOG+='**Manual:** download '"\`${ZIP_NAME}\`"' below, unzip, drag Mainline.app to /Applications.'$'\n\n'
CHANGELOG+='**Requirements:** macOS 13.0+.'$'\n'

# =============================================================================
# GitHub release
# =============================================================================
log_info "Creating GitHub release..."

PRERELEASE_FLAG=""
TITLE="${PROJECT_NAME} ${TAG}"
if [ "$IS_BETA" = "true" ]; then
  PRERELEASE_FLAG="--prerelease"
  TITLE="${PROJECT_NAME} ${TAG} (beta)"
fi

if [ "${DRY_RUN:-}" = "true" ]; then
  log_warning "DRY_RUN: would create release $TAG"
  echo "$CHANGELOG" | head -30
else
  echo "$CHANGELOG" | gh release create "$TAG" \
    $PRERELEASE_FLAG \
    --title "$TITLE" \
    --notes-file - \
    "$ZIP_PATH"
  log_success "GitHub release created"
fi

# =============================================================================
# Update homebrew tap
# =============================================================================
if [ -z "${HOMEBREW_TAP_TOKEN:-}" ]; then
  log_warning "HOMEBREW_TAP_TOKEN not set — skipping tap update"
  exit 0
fi

if [ "${DRY_RUN:-}" = "true" ]; then
  log_warning "DRY_RUN: would update tap repo"
  exit 0
fi

log_info "Updating mthines/homebrew-mainline..."

# The source-of-truth cask lives in the app repo. We copy it wholesale to the
# tap on every release so any change (depends_on, desc, zap, caveats) propagates
# automatically — sed only patches version + sha256 on top.
SOURCE_CASK="$PROJECT_DIR/Casks/mainline.rb"

TAP_DIR="/tmp/homebrew-mainline-ci"
rm -rf "$TAP_DIR"
git clone "https://x-access-token:${HOMEBREW_TAP_TOKEN}@github.com/mthines/homebrew-mainline.git" "$TAP_DIR"

cd "$TAP_DIR"
git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"
mkdir -p Casks

if [ "$IS_BETA" = "true" ]; then
  BETA_CASK="Casks/mainline-beta.rb"
  cp "$SOURCE_CASK" "$BETA_CASK"
  sed -i '' 's/cask "mainline"/cask "mainline-beta"/' "$BETA_CASK"
  sed -i '' "s/version \"[^\"]*\"/version \"${VERSION}\"/" "$BETA_CASK"
  sed -i '' "s/sha256 \"[^\"]*\"/sha256 \"${ZIP_SHA}\"/" "$BETA_CASK"

  # Pinned beta for reproducible installs
  VERSIONED_CASK="Casks/mainline-beta@${VERSION}.rb"
  cp "$BETA_CASK" "$VERSIONED_CASK"
  sed -i '' "s/cask \"mainline-beta\"/cask \"mainline-beta@${VERSION}\"/" "$VERSIONED_CASK"

  git add "$BETA_CASK" "$VERSIONED_CASK"
  git commit -m "mainline-beta: update to ${TAG}"
  log_success "Updated mainline-beta.rb + mainline-beta@${VERSION}.rb"
else
  STABLE_CASK="Casks/mainline.rb"
  cp "$SOURCE_CASK" "$STABLE_CASK"
  sed -i '' "s/version \"[^\"]*\"/version \"${VERSION}\"/" "$STABLE_CASK"
  sed -i '' "s/sha256 \"[^\"]*\"/sha256 \"${ZIP_SHA}\"/" "$STABLE_CASK"

  git add "$STABLE_CASK"
  git commit -m "mainline: update to ${TAG}"
  log_success "Updated mainline.rb"
fi

git remote set-url origin "https://x-access-token:${HOMEBREW_TAP_TOKEN}@github.com/mthines/homebrew-mainline.git"
git push origin main

cd "$PROJECT_DIR"
rm -rf "$TAP_DIR"

log_success "Released ${TAG}"
echo "Release URL: https://github.com/mthines/mainline/releases/tag/${TAG}"
