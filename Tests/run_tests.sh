#!/bin/zsh
# Compile and run tests against child listeners created by the harness itself.
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p Tests/.build/ModuleCache
LC_ALL=C /usr/bin/shasum -a 256 Sources/ProcessBridge.c Sources/ProcessBridge.h Sources/PortCore.swift Tests/TestMain.swift Tests/test_listener.c Tests/identifier_tests.c > Tests/tested_sources.sha256
SDK_PATH="$(xcrun --show-sdk-path)"
clang -O2 -Wall -Wextra -isysroot "$SDK_PATH" -mmacosx-version-min=14.0 Tests/test_listener.c -o Tests/.build/test_listener
clang -O2 -Wall -Wextra -isysroot "$SDK_PATH" -mmacosx-version-min=14.0 -c Sources/ProcessBridge.c -o Tests/.build/ProcessBridge.o
clang -O2 -Wall -Wextra -isysroot "$SDK_PATH" -mmacosx-version-min=14.0 Tests/identifier_tests.c Tests/.build/ProcessBridge.o -o Tests/.build/identifier_tests
Tests/.build/identifier_tests | tee Tests/identifier_test_report.txt
swiftc -O -swift-version 5 -sdk "$SDK_PATH" -target arm64-apple-macosx14.0 -module-cache-path Tests/.build/ModuleCache -import-objc-header Sources/ProcessBridge.h Sources/PortCore.swift Tests/TestMain.swift Tests/.build/ProcessBridge.o -o Tests/.build/core_tests
Tests/.build/core_tests "$PWD/Tests/.build/test_listener" "$PWD/Tests/integration_report.json" | tee Tests/integration_test_report.txt
