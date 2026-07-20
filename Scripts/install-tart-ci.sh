#!/bin/zsh
set -euo pipefail

BREW="$(command -v brew)"
"$BREW" tap cirruslabs/cli
"$BREW" trust --formula cirruslabs/cli/softnet
"$BREW" install cirruslabs/cli/tart
"$("$BREW" --prefix)/bin/tart" --version
