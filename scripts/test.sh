#!/bin/zsh
# Compiles the data, agent, API, and provider layers with headless harnesses and runs them against a local mock server.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos14.0" -lsqlite3 \
  Sources/DoResearch/Data/*.swift Sources/DoResearch/Agent/*.swift Sources/DoResearch/API/*.swift Sources/DoResearch/Operations/*.swift Tests/*.swift \
  -o build/tool-harness

LOGDIR=$(mktemp -d)
PORT=$((20000 + RANDOM % 20000))
python3 -I Tests/mock/mock_server.py $PORT "$LOGDIR" &
MOCK=$!
trap 'kill $MOCK 2>/dev/null; rm -rf "$LOGDIR"' EXIT
for _ in {1..50}; do nc -z 127.0.0.1 $PORT 2>/dev/null && break; sleep 0.1; done

# Keep real keys out of the tests.
env -u ANTHROPIC_API_KEY -u OPENAI_API_KEY MOCK_PORT=$PORT MOCK_LOG="$LOGDIR" ./build/tool-harness
