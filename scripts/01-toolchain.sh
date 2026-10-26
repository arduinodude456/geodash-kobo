#!/usr/bin/env bash
# Builds koxtoolchain for the "kobo" target (arm-kobo-linux-gnueabihf).
set -euo pipefail
cd "$HOME"
git clone --depth 1 https://github.com/koreader/koxtoolchain.git
cd koxtoolchain
./gen-tc.sh kobo
ls "$HOME/x-tools"
