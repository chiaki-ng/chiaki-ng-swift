#!/bin/zsh
set -eu
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
"$project_dir/Scripts/build-core.sh"
configuration="${CONFIGURATION:-debug}"
swift_command="${SWIFT:-swift}"
case "$configuration" in
    debug)
        bundle_id=io.github.chiaki-ng.chiaki-ng.debug
        bundle_name='chiaki-ng Debug'
        ;;
    release)
        bundle_id=io.github.chiaki-ng.chiaki-ng
        bundle_name=chiaki-ng
        ;;
    *) echo 'CONFIGURATION must be debug or release' >&2; exit 1 ;;
esac
app_store="${CHIAKI_APP_STORE:-0}"
swift_flags=()
app_dir="$project_dir/.build/chiaki-ng.app"
if [[ "$app_store" == 1 ]]; then
    if [[ "$configuration" != release ]]; then
        echo 'CHIAKI_APP_STORE=1 needs CONFIGURATION=release' >&2
        exit 1
    fi
    bundle_id=io.github.chiaki-ng.chiaki-ng.appstore
    swift_flags=(--scratch-path "$project_dir/.build/app-store" -Xswiftc -DCHIAKI_APP_STORE)
    app_dir="$project_dir/.build/app-store/chiaki-ng.app"
fi
version_tag="${CHIAKI_VERSION_TAG:-}"
if [[ -n "$version_tag" && ! "$version_tag" =~ '^[A-Za-z0-9][A-Za-z0-9.-]*$' ]]; then
    echo 'TAG may contain only letters, digits, dots and hyphens, and must start with a letter or digit' >&2
    exit 1
fi
"$swift_command" build --package-path "$project_dir" --configuration "$configuration" "${swift_flags[@]}"
bin_dir="$("$swift_command" build --package-path "$project_dir" --configuration "$configuration" "${swift_flags[@]}" \
    --show-bin-path)"
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
mkdir -p "$app_dir/Contents/Frameworks"
dependency_prefix="$(python3 "$project_dir/Tools/Dependencies/build.py" --prefix)"
ditto "$dependency_prefix/share/licenses" "$app_dir/Contents/Resources/Licenses"
# Bundle the canonical zh-Hans dictionary in the app's main bundle.
if [[ -f "$project_dir/Localization/zh-Hans.lproj/Localizable.strings" ]]; then
    mkdir -p "$app_dir/Contents/Resources/zh-Hans.lproj"
    cp "$project_dir/Localization/zh-Hans.lproj/Localizable.strings" \
        "$app_dir/Contents/Resources/zh-Hans.lproj/Localizable.strings"
fi
cp "$project_dir/.build/native-core/libChiakiRegistration.dylib" "$app_dir/Contents/Frameworks/"
cp "$project_dir/.build/native-core/libChiakiInput.dylib" "$app_dir/Contents/Frameworks/"
cp "$project_dir/.build/native-core/libSDL3.0.dylib" "$app_dir/Contents/Frameworks/"
cp "$bin_dir/ChiakiNG" "$app_dir/Contents/MacOS/ChiakiNG"
for resource_bundle in "$bin_dir"/*.bundle; do
    ditto "$resource_bundle" "$app_dir/Contents/Resources/$(basename "$resource_bundle")"
done
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>chiaki-ng</string>
<key>CFBundleDisplayName</key><string>chiaki-ng</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
<key>CFBundleIdentifier</key><string>BUNDLE_ID</string>
<key>CFBundleExecutable</key><string>ChiakiNG</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>2.0.0</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSMicrophoneUsageDescription</key><string>Talk to other players through your PlayStation console while you stream.</string>
<key>NSLocalNetworkUsageDescription</key><string>Find your PlayStation consoles on local networks and configured discovery subnets.</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSApplicationCategoryType</key><string>public.app-category.games</string>
<key>LSSupportsGameMode</key><true/>
<key>ITSAppUsesNonExemptEncryption</key><false/>
<key>UTExportedTypeDeclarations</key><array><dict>
<key>UTTypeIdentifier</key><string>io.github.chiaki-ng.kakusan</string>
<key>UTTypeDescription</key><string>Kakusan invitation or reply</string>
<key>UTTypeConformsTo</key><array><string>public.data</string><string>public.content</string></array>
<key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>kakusan</string></array></dict>
</dict></array>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>Kakusan invitation or reply</string>
<key>CFBundleTypeRole</key><string>Viewer</string>
<key>LSHandlerRank</key><string>Owner</string>
<key>LSItemContentTypes</key><array><string>io.github.chiaki-ng.kakusan</string></array>
</dict></array>
<key>CFBundleURLTypes</key><array><dict>
<key>CFBundleURLName</key><string>BUNDLE_ID.stream</string>
<key>CFBundleTypeRole</key><string>Viewer</string>
<key>CFBundleURLSchemes</key><array><string>chiaki-ng</string></array>
</dict></array>
</dict></plist>
PLIST
icon_source="$project_dir/Assets/Images/Branding/chiaking-color.png"
icon_dir="$project_dir/.build/app-icon/${version_tag:-untagged}"
icon_cache="$icon_dir/AppIcon.icns"
if [[ ! -f "$icon_cache" || "$icon_source" -nt "$icon_cache" || "$project_dir/Tools/Packaging/app-icon.swift" -nt "$icon_cache" ]]; then
    rm -rf "$icon_dir"
    swift "$project_dir/Tools/Packaging/app-icon.swift" "$icon_source" "$icon_dir/AppIcon.iconset" ${version_tag:+"$version_tag"}
    iconutil -c icns "$icon_dir/AppIcon.iconset" -o "$icon_cache"
fi
cp "$icon_cache" "$app_dir/Contents/Resources/AppIcon.icns"
build_counter="$project_dir/.build/build-number"
build_number=1
if [[ -f "$build_counter" ]]; then
    previous_build="$(cat "$build_counter")"
    if [[ "$previous_build" == <-> ]]; then build_number=$((previous_build + 1)); fi
fi
if [[ "$app_store" == 1 ]]; then
    build_number="$(date -u +%y%m%d%H%M)"
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" \
    -c "Set :CFBundleIdentifier $bundle_id" \
    -c "Set :CFBundleURLTypes:0:CFBundleURLName $bundle_id.stream" \
    -c "Set :CFBundleName $bundle_name" \
    -c "Set :CFBundleDisplayName $bundle_name" "$app_dir/Contents/Info.plist"
if [[ "$app_store" != 1 ]]; then
    printf '%s\n' "$build_number" > "$build_counter"
fi
if [[ "${CHIAKI_KAKUSAN:-0}" == 0 ]]; then
    /usr/libexec/PlistBuddy -c "Delete :UTExportedTypeDeclarations" -c "Delete :CFBundleDocumentTypes" \
        "$app_dir/Contents/Info.plist"
fi
if [[ -n "$version_tag" ]]; then
    /usr/libexec/PlistBuddy -c "Add :ChiakiVersionTag string $version_tag" "$app_dir/Contents/Info.plist"
fi
commit="$(git -C "$project_dir" rev-parse --short=8 HEAD 2>/dev/null || true)"
if [[ -n "$commit" ]] && ! git -C "$project_dir" diff --quiet HEAD -- 2>/dev/null; then
    commit="$commit-modified"
fi
if [[ -n "$commit" ]]; then
    /usr/libexec/PlistBuddy -c "Add :ChiakiCommit string $commit" "$app_dir/Contents/Info.plist"
fi
codesign --remove-signature "$app_dir/Contents/MacOS/ChiakiNG"
"$project_dir/Tools/Packaging/bundle-dylibs.sh" \
    "$app_dir" \
    "$app_dir/Contents/MacOS/ChiakiNG" \
    "$app_dir/Contents/Frameworks/libChiakiRegistration.dylib" \
    "$app_dir/Contents/Frameworks/libChiakiInput.dylib"
python3 "$project_dir/Tools/Packaging/verify-macos.py" "$app_dir"
signing_identity="${CHIAKI_CODE_SIGN_IDENTITY:-}"
identity_file="$project_dir/.local-signing/identity"
if [[ -z "$signing_identity" && -f "$identity_file" ]]; then
    signing_identity="$(cat "$identity_file")"
fi
if [[ -z "$signing_identity" ]]; then
    signing_identity="-"
fi
codesign --force --deep --sign "$signing_identity" --identifier "$bundle_id" "$app_dir"
codesign --verify --deep --strict "$app_dir"
if [[ "${CHIAKI_LAUNCH_APP:-1}" == 1 ]]; then
    open -n "$app_dir"
else
    printf 'Built %s\n' "$app_dir"
fi
