#!/usr/bin/env bash
# Compiles Mainline's pure Foundation-only sources with a Linux (or macOS) Swift toolchain and
# runs their #if DEBUG self-checks, so hook/issue/flag logic can be checked without Xcode.
# Usage: SWIFTC=/path/to/swiftc bash scripts/selfcheck-linux/build.sh   (default: swiftc on PATH)
set -euo pipefail
H="$(cd "$(dirname "$0")" && pwd)"
S="$H/../../Mainline/Mainline"
OUT="${TMPDIR:-/tmp}/mainline-selfcheck"
"${SWIFTC:-swiftc}" -D DEBUG -Onone -swift-version 5 -o "$OUT" \
  "$S/Services/PRHookEngine.swift" "$S/Services/IssueDiffEngine.swift" "$S/Models/IssueSnapshot.swift" \
  "$S/Models/PRSnapshot.swift" "$S/Services/PromptTemplate.swift" "$S/Services/CommentTemplate.swift" \
  "$S/Models/AttentionPolicy.swift" "$S/Services/PRListExport.swift" "$S/Services/StackEngine.swift" \
  "$S"/Services/FeatureFlags/*.swift "$H/stubs.swift" "$H/main.swift"
"$OUT"
