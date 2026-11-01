#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
sdk="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
[[ -d "$sdk" ]] || sdk="$(xcrun --show-sdk-path)"
zsh Tools/build-webp.sh "$sdk"
mkdir -p build/port-tests
clang -target arm64-apple-macosx14.0 -isysroot "$sdk" -c Sources/ChargeShared/BDPolicy.c -I Sources/ChargeShared/include -o build/port-tests/policy.o
swiftc -sdk "$sdk" -target arm64-apple-macosx14.0 -Xfrontend -interface-compiler-version -Xfrontend 6.3.2 \
    -I Sources/ChargeShared/include -I Sources/CSQLite -I Sources/CWebP \
    Sources/Vorssaint/Services/BatteryHistory/Energy.swift Sources/Vorssaint/Services/BatteryHistory/EnergyDatabase.swift \
    Sources/Vorssaint/Services/FinderMenu/FinderMenuContract.swift Sources/Vorssaint/Services/FinderMenu/FinderFileCopy.swift \
    Sources/Vorssaint/Services/Media/WebPEncoder.swift Tests/Port/main.swift build/port-tests/policy.o \
    build/webp-source/src/libwebp.a build/webp-source/sharpyuv/libsharpyuv.a -o build/port-tests/check
build/port-tests/check
