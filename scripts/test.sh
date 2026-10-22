#!/bin/bash
# Runs the test suite. With only the Command Line Tools installed (no Xcode),
# Swift Testing ships but isn't on the default search paths, so add them.
set -euo pipefail
cd "$(dirname "$0")/.."

DEV=/Library/Developer/CommandLineTools/Library/Developer
if xcode-select -p | grep -q CommandLineTools && [ -d "$DEV/Frameworks/Testing.framework" ]; then
    exec swift test \
        -Xswiftc -F"$DEV/Frameworks" \
        -Xlinker -F"$DEV/Frameworks" \
        -Xlinker -rpath -Xlinker "$DEV/Frameworks" \
        -Xlinker -rpath -Xlinker "$DEV/usr/lib" \
        "$@"
fi
exec swift test "$@"
