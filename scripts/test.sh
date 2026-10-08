#!/bin/zsh
# Compiles the data + agent-tool layers with a headless harness and runs it.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos14.0" -lsqlite3 \
  Sources/DoResearch/Data/*.swift Sources/DoResearch/Agent/AgentTools.swift Tests/ToolHarness.swift \
  -o build/tool-harness
./build/tool-harness
