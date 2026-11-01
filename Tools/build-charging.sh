#!/bin/zsh
set -euo pipefail
sdk="$1"
target="$2"
mkdir -p build/charging
clang -target "$target" -isysroot "$sdk" -c Sources/ChargeShared/BDPolicy.c -I Sources/ChargeShared/include -o build/charging/policy.o
clang -target "$target" -isysroot "$sdk" -fobjc-arc -fmodules -I Sources/ChargeShared/include -I Sources/ChargeRuntime/include Sources/ChargeRuntime/NativeBackend.m Sources/ChargeDaemon/main.m build/charging/policy.o -framework Foundation -framework Security -framework IOKit -framework SystemConfiguration -o build/VorssaintChargeHelper
