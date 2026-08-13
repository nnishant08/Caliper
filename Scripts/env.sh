#!/usr/bin/env bash
#
# Shared environment for the other scripts. Source it, don't run it.
#
# `xcode-select` on this machine may still point at the Command Line Tools
# instance, which has no Swift Testing and no simulators. Setting DEVELOPER_DIR
# overrides that per-process and needs no sudo, so the scripts work whether or
# not the global switch has been made.

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
