#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
deployment_target=16.0
version=$(awk '/^core_version:/ { print $2; exit }' "$repo/build_config.yaml")

if [[ $# -eq 0 ]]; then set -- iphoneos iphonesimulator; fi
for platform in "$@"; do
    case "$platform" in
      iphoneos) triple="arm64-apple-ios${deployment_target}" ;;
      iphonesimulator) triple="arm64-apple-ios${deployment_target}-simulator" ;;
      *) printf 'Unsupported iOS SDK: %s\n' "$platform" >&2; exit 1 ;;
    esac
    sdk_path=$(xcrun --sdk "$platform" --show-sdk-path)
    clang=$(xcrun --sdk "$platform" --find clang)
    output="$repo/ios/NativeCore/build/$platform"
    mkdir -p "$output"
    (
      cd "$repo/core"
      export GOOS=ios GOARCH=arm64 CGO_ENABLED=1 CC="$clang"
      export CGO_CFLAGS="-target $triple -isysroot $sdk_path"
      export CGO_LDFLAGS="$CGO_CFLAGS"
      go build -mod=readonly -trimpath -tags with_gvisor -buildmode=c-archive \
        -ldflags "-w -s -X github.com/metacubex/mihomo/constant.Version=$version" \
        -o "$output/libFlClashCore.a" "$repo/ios/NativeCore/main.go"
    )
    xcrun lipo -verify_arch arm64 "$output/libFlClashCore.a"
    xcrun nm -gUj "$output/libFlClashCore.a" > "$output/exports.txt"
    awk 'match($0, /flclash_core_[a-z_]+\(/) { print substr($0, RSTART, RLENGTH - 1) }' \
      "$repo/ios/NativeCore/FlClashCore.h" > "$output/expected-exports.txt"
    test -s "$output/expected-exports.txt"
    while IFS= read -r symbol; do
      if ! grep -Fxq "_$symbol" "$output/exports.txt"; then
        printf '%s: missing C export %s\n' "$platform" "$symbol" >&2
        exit 1
      fi
      printf '%s: verified C export %s\n' "$platform" "$symbol"
    done < "$output/expected-exports.txt"
done
