#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
platform="${CHIAKI_PLATFORM:-macos}"
case "${CHIAKI_KAKUSAN:-0}" in
    1) kakusan=ON ;;
    0) kakusan=OFF ;;
    *)
        echo 'CHIAKI_KAKUSAN must be 1 or 0' >&2
        exit 1
        ;;
esac
case "${CHIAKI_PS5_CLOUD_LAUNCH:-0}" in
    1) ps5_cloud_launch=ON ;;
    0) ps5_cloud_launch=OFF ;;
    *)
        echo 'CHIAKI_PS5_CLOUD_LAUNCH must be 1 or 0' >&2
        exit 1
        ;;
esac
case "$platform" in
    macos)
        build_dir="$project_dir/.build/native-core"
        platform_options=()
        ;;
    ios)
        build_dir="$project_dir/.build/native-core-ios"
        platform_options=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos)
        ;;
    ios-simulator)
        build_dir="$project_dir/.build/native-core-ios-simulator"
        platform_options=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphonesimulator)
        ;;
    *)
        echo 'CHIAKI_PLATFORM must be macos, ios or ios-simulator' >&2
        exit 1
        ;;
esac

for tool in cmake ninja pkg-config; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Missing build tool: $tool" >&2
        exit 1
    fi
done
python3 "$project_dir/Tools/Dependencies/build.py" "--platform=$platform"
dependency_prefix="$(python3 "$project_dir/Tools/Dependencies/build.py" "--platform=$platform" --prefix)"
if [[ "$platform" != macos ]]; then
    platform_options+=(-DCMAKE_OSX_ARCHITECTURES=arm64
        -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH
        -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH)
fi
export PKG_CONFIG_PATH="$dependency_prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
for package in libavcodec libavutil libavformat libcurl openssl opus; do
    if [[ "$(pkg-config --variable=prefix "$package")" != "$dependency_prefix" ]]; then
        echo "Refusing unpinned dependency: $package" >&2
        exit 1
    fi
done
if [[ ! -e "$project_dir/lib/chiaki-ng-core/.git" ]]; then
    git -C "$project_dir" submodule update --init lib/chiaki-ng-core
fi

cmake -S "$project_dir/lib" -B "$build_dir" -G Ninja \
    -U "*FFMPEG*" -U "*CURL*" -U "*OPENSSL*" -U "*OPUS*" -U "*MINIUPNPC*" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DOPENSSL_ROOT_DIR="$dependency_prefix" \
    -DOPENSSL_CRYPTO_LIBRARY="$dependency_prefix/lib/libcrypto.dylib" \
    -DOPENSSL_SSL_LIBRARY="$dependency_prefix/lib/libssl.dylib" \
    -DOPENSSL_INCLUDE_DIR="$dependency_prefix/include" \
    -DCURL_DIR="$dependency_prefix/lib/cmake/CURL" \
    -DCMAKE_PREFIX_PATH="$dependency_prefix" \
    -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local;/opt/local" \
    -DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF \
    -DBUILD_SHARED_LIBS=OFF \
    -DLIBCHIAKING_TAKION_VERSION_OVERRIDE="${CHIAKI_TAKION_VERSION:-0}" \
    -DLIBCHIAKING_KAKUSAN="$kakusan" \
    -DLIBCHIAKING_PS5_CLOUD_LAUNCH="$ps5_cloud_launch" \
    ${platform_options[@]+"${platform_options[@]}"}
libraries=("$build_dir"/libChiakiRegistration.dylib "$build_dir"/libChiakiInput.dylib)
if [[ "$platform" != macos ]]; then
    cmake --build "$build_dir" --target ChiakiInput ChiakiRegistration --parallel
    python3 "$project_dir/Tools/Packaging/verify-ios.py" "$platform" "--allow=$dependency_prefix" \
        "${libraries[@]}" "$build_dir"/libSDL3.0.dylib
    exit 0
fi
if [[ "${CHIAKI_BUILD_ONLY:-0}" == 1 ]]; then
    cmake --build "$build_dir" --target ChiakiInput ChiakiRegistration --parallel
    exit 0
fi
core_tests=(public chiaki_ng default_platform)
core_targets=("${core_tests[@]/#/api_}")
core_targets=("${core_targets[@]/%/_gtests}")
kakusan_targets=()
if [[ "$kakusan" == ON ]]; then
    kakusan_targets=(chiaki-kakusan-pair-test)
fi
cmake --build "$build_dir" --target chiaki-audio-format-test chiaki-bridge-log-test chiaki-domains-test chiaki-scripted-session-test ${kakusan_targets[@]+"${kakusan_targets[@]}"} chiaki-bridge-facts-test chiaki-secret-residue-test chiaki-caches-bridge-test chiaki-catalog-bridge-test chiaki-http-calls-bridge-test chiaki-users-bridge-test chiaki-audio-test chiaki-input-test chiaki-haptic-rumble-test chiaki-switch-rumble-test chiaki-dualsense-test chiaki-input-commands-test ChiakiInput ChiakiRegistration chiaki-motion-test chiaki-microphone-test "${core_targets[@]}" --parallel
core_pattern="$(IFS='|'; echo "${core_tests[*]}")"
ctest --test-dir "$build_dir" --output-on-failure -R "^chiaki-|^api/(${core_pattern})/"
for library in "${libraries[@]}"; do
    if otool -L "$library" | tail -n +2 | grep -E '^\s*(/opt/homebrew|/usr/local|/opt/local)/'; then
        echo "Refusing $library: it links a library outside the pinned dependency prefix" >&2
        exit 1
    fi
    if otool -l "$library" | awk '/minos/ { print $2 }' | grep -vx '26.0'; then
        echo "Refusing $library: it does not target macOS 26.0" >&2
        exit 1
    fi
done
