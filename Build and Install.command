#!/bin/bash
# Double-click in Finder (not Xcode) to build and install CustomMacOS.
# In Xcode, open CustomMacOS.xcodeproj and use Product → Build (⌘B) instead.
cd "$(dirname "$0")"
./build.sh --install
