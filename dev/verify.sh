#!/bin/sh
# Runs both headless-Chrome check suites (needs puppeteer-core + a Chrome binary; see README).
# Usage: NODE_PATH=/path/to/node_modules dev/verify.sh
set -e
cd "$(dirname "$0")/.."
ruby build_atlas.rb
node dev/verify_shoot.js
node dev/verify_v2.js
