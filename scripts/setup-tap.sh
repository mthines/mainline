#!/bin/bash
# =============================================================================
# Homebrew Tap Setup Script
# Creates the homebrew-mainline tap repository for distribution
# =============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}i${NC} $1"; }
log_success() { echo -e "${GREEN}ok${NC} $1"; }
log_warning() { echo -e "${YELLOW}warn${NC} $1"; }
log_error() { echo -e "${RED}err${NC} $1"; exit 1; }

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAP_DIR="${1:-$PROJECT_DIR/../homebrew-mainline}"

echo ""
echo "Homebrew Tap Setup"
echo "=================="
echo ""

# Check if tap directory already exists
if [ -d "$TAP_DIR" ]; then
    log_warning "Tap directory already exists: $TAP_DIR"
    read -r -p "Update existing tap? (Y/n) " reply
    echo ""
    if [[ "$reply" =~ ^[Nn]$ ]]; then
        exit 0
    fi
else
    # Create tap directory
    mkdir -p "$TAP_DIR"
    log_success "Created tap directory: $TAP_DIR"

    # Initialize git repo
    cd "$TAP_DIR"
    git init
    log_success "Initialized git repository"
fi

cd "$TAP_DIR"

# Create Casks directory
mkdir -p Casks

# Copy cask file
cp "$PROJECT_DIR/Casks/mainline.rb" Casks/
log_success "Copied mainline.rb to Casks/"

# Create README
cat > README.md << 'READMEEOF'
# Homebrew Tap for Mainline

This is the official Homebrew tap for [Mainline](https://github.com/mthines/mainline), a lightweight macOS menu bar app for GitHub pull request notifications.

## Installation

```bash
brew tap mthines/mainline
brew install --cask mainline
```

## Updating

```bash
brew upgrade --cask mainline
```

## Uninstalling

```bash
brew uninstall --cask mainline
brew untap mthines/mainline
```

## Beta Releases

Beta releases are published for every non-draft pull request:

```bash
brew tap mthines/mainline
brew install --cask --force mthines/mainline/mainline-beta
```

## Requirements

- macOS 13.0 (Ventura) or later
- A GitHub Personal Access Token with `repo` scope

## About

Mainline notifies you about GitHub pull request activity directly in your menu bar — new PRs, CI status changes, reviews, and comments. No browser tab required.

See the [main repository](https://github.com/mthines/mainline) for full documentation.
READMEEOF
log_success "Created README.md"

# Show next steps
echo ""
log_success "Tap setup complete!"
echo ""
echo "Next steps:"
echo ""
echo "1. Create a GitHub repository named 'homebrew-mainline'"
echo "   https://github.com/new"
echo ""
echo "2. Push the tap:"
echo "   cd $TAP_DIR"
echo "   git add ."
echo "   git commit -m 'Initial tap setup'"
echo "   git remote add origin https://github.com/mthines/homebrew-mainline.git"
echo "   git push -u origin main"
echo ""
echo "3. Add the HOMEBREW_TAP_TOKEN secret to your GitHub repository:"
echo "   https://github.com/mthines/mainline/settings/secrets/actions"
echo "   (needs 'repo' scope on mthines/homebrew-mainline)"
echo ""
echo "4. Users can then install with:"
echo "   brew tap mthines/mainline"
echo "   brew install --cask mainline"
echo ""
