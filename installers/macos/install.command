#!/bin/bash
# TypingIndicators - https://github.com/TheAstroMirth/TypingIndicators
# Installer scripts: Copyright (c) 2026 TheAstroMirth.
# Licensed under the GNU General Public License v3.0. See LICENSE and NOTICE.md.
#
# Double-click this file in Finder to run the TypingIndicators installer in Terminal.
# It only starts install.sh from the same folder and keeps the window open afterwards.

finish() {
    echo
    printf 'Press Return to close this window. '
    IFS= read -r _ || true
    exit "$1"
}

# Ctrl+C should stop install.sh (which cleans up after itself), not this window.
trap : INT

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || HERE=""
if [ -z "$HERE" ]; then
    echo "Cannot work out which folder this file is in."
    echo "Unzip the whole project first and run it from there."
    finish 1
fi
for needed in install.sh common.sh; do
    if [ ! -r "$HERE/$needed" ]; then
        echo "Cannot find $needed next to this file:"
        echo "  $HERE"
        echo "Unzip the whole project first and keep its folders together."
        finish 1
    fi
done

/bin/bash "$HERE/install.sh" "$@"
rc=$?
if [ "$rc" -ne 0 ]; then
    echo
    echo "The installer stopped before finishing (exit code $rc). Read the messages above."
fi
finish "$rc"
