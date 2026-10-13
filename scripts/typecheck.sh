#!/bin/zsh
# Typecheck Core + one or more feature folders without a full build.
# Usage: scripts/typecheck.sh Uninstaller [Cleaner ...]   (no args = whole app)
set -e
cd "$(dirname "$0")/.."
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
files=($(find Sources/MacMaster/Core -name '*.swift'))
if [[ $# -eq 0 ]]; then
  files=($(find Sources/MacMaster -name '*.swift'))
else
  for f in "$@"; do files+=($(find Sources/MacMaster/Features/$f -name '*.swift')); done
  # standalone check needs an entry point
  stub=$(mktemp -d)/Stub.swift
  echo 'import SwiftUI
@main struct TypecheckStub: App { var body: some Scene { WindowGroup { EmptyView() } } }' > $stub
  files+=($stub)
fi
swiftc -typecheck -parse-as-library -swift-version 5 -sdk $SDK -target arm64-apple-macos14 $files
echo "TYPECHECK OK"
