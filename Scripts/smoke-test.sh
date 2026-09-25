#!/bin/sh
#
# The exit criteria of every milestone so far, as checks rather than claims:
# build the app and verify that the engine it carries actually works.
#
#     Scripts/smoke-test.sh [Debug|Release]
#
# Release is the interesting one -- that is where the framework has to come out
# universal.
#
set -eu

CONFIG=${1:-Release}
REPO_ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
check() {  # check <description> <expected> <actual>
    if [ "$2" = "$3" ]; then
        printf '  ok    %s\n' "$1"
        pass=$((pass + 1))
    else
        printf '  FAIL  %s\n        expected: %s\n        actual:   %s\n' "$1" "$2" "$3"
        fail=$((fail + 1))
    fi
}

# `xcodebuild -scheme` with no destination resolves to this Mac and narrows
# ARCHS to the native one, so a Release build comes out arm64-only. The generic
# destination is what produces the universal binary we ship.
printf 'building 7-Mac (%s)\n' "$CONFIG"
xcodebuild -project "$REPO_ROOT/7-Mac.xcodeproj" -scheme 7-Mac -configuration "$CONFIG" \
           -destination 'generic/platform=macOS' \
           -derivedDataPath "$WORK/dd" build >"$WORK/build.log" 2>&1 || {
    tail -40 "$WORK/build.log" >&2
    printf 'build failed; full log at %s\n' "$WORK/build.log" >&2
    exit 1
}

PRODUCTS="$WORK/dd/Build/Products/$CONFIG"
APP="$PRODUCTS/7-Mac.app"
FRAMEWORKS="$APP/Contents/Frameworks"
BINARY="$FRAMEWORKS/SevenZipKit.framework/Versions/A/SevenZipKit"

printf '\nbundle layout\n'
check "the app exists"              "yes" "$([ -d "$APP" ] && echo yes || echo no)"
check "the framework is embedded"   "yes" "$([ -f "$BINARY" ] && echo yes || echo no)"
check "the framework is signed"     "yes" "$(codesign -v "$FRAMEWORKS/SevenZipKit.framework" 2>/dev/null && echo yes || echo no)"
check "licence texts ship with it"  "3"   "$(find "$FRAMEWORKS/SevenZipKit.framework/Versions/A/Resources" -name '7-Zip-*' 2>/dev/null | wc -l | tr -d ' ')"

printf '\nlinkage\n'
# Roadmap risk 2: upstream's dylib is born as b/m_arm64/7z.so, which the app
# cannot load.
check "install_name is @rpath-relative" \
      "@rpath/SevenZipKit.framework/Versions/A/SevenZipKit" \
      "$(otool -D "$BINARY" | tail -1)"

# Nothing from Homebrew, nothing to install alongside. Note that otool prints
# one section per slice for a universal binary, so collect and dedupe the
# indented dependency lines rather than slicing by line number.
foreign=$(otool -L "$BINARY" \
          | grep '^	' | awk '{print $1}' | sort -u \
          | grep -vE '^(/usr/lib/|/System/Library/Frameworks/|@rpath/SevenZipKit\.framework/)' \
          | tr '\n' ' ')
check "no non-system dependencies" "" "$foreign"

if [ "$CONFIG" = "Release" ]; then
    check "the framework is universal" "x86_64 arm64" "$(lipo -archs "$BINARY")"
    check "the app is universal"       "x86_64 arm64" "$(lipo -archs "$APP/Contents/MacOS/7-Mac")"
fi

printf '\nengine\n'
# Ask the engine what it can actually do. This is the part that catches a
# -force_load regression: drop that flag and every check above still passes
# while the count here falls to zero.
#
# Headers come from the build products copy, because the embedded one has had
# them stripped on copy. The binary that gets *loaded* is still the embedded
# one -- install_name is @rpath-relative and the rpath below points into the
# app bundle -- and the probe reports back which copy it got.
cat > "$WORK/probe.m" <<'PROBE'
#import <SevenZipKit/SevenZipKit.h>
#import <stdio.h>
int main(void) {
    @autoreleasepool {
        NSMutableArray *writable = [NSMutableArray array];
        for (SZKFormat *f in SZKEngine.writableFormats) [writable addObject:f.name];
        [writable sortUsingSelector:@selector(compare:)];
        printf("%s\n", SZKEngine.upstreamVersion.UTF8String);
        printf("%lu\n", (unsigned long)SZKEngine.formats.count);
        printf("%s\n", [writable componentsJoinedByString:@" "].UTF8String);
        printf("%s\n", [[SZKEngine formatNamed:@"gzip"] wrappedExtensionForFileExtension:@"tgz"].UTF8String);
        printf("%d\n", [SZKEngine formatNamed:@"zstd"].isWritable);
        printf("%s\n", [NSBundle bundleForClass:SZKEngine.class].bundlePath.UTF8String);
    }
    return 0;
}
PROBE

clang -fobjc-arc -o "$WORK/probe" "$WORK/probe.m" \
      -F "$PRODUCTS" -framework SevenZipKit -framework Foundation \
      -Wl,-rpath,"$FRAMEWORKS" >>"$WORK/build.log" 2>&1 || {
    printf '  FAIL  could not link against the embedded framework\n'
    exit 1
}
"$WORK/probe" > "$WORK/probe.out"

check "engine reports its version"  "26.03" "$(sed -n 1p "$WORK/probe.out")"
check "60 formats are registered"   "60"    "$(sed -n 2p "$WORK/probe.out")"
check "the 7 writable formats"      "7z bzip2 gzip tar wim xz zip" "$(sed -n 3p "$WORK/probe.out")"
check "gzip unwraps .tgz to tar"    "tar"  "$(sed -n 4p "$WORK/probe.out")"
# Accepted limit, not a gap to fill: zstd reads but never writes.
check "zstd is read-only"           "0"     "$(sed -n 5p "$WORK/probe.out")"
check "the embedded copy is the one that loads" \
      "$FRAMEWORKS/SevenZipKit.framework" "$(sed -n 6p "$WORK/probe.out")"

printf '\nfinder integration\n'
# M2 puts the app in front of the Finder: double-clicking an archive and the
# two Services entries. All three live in Info.plist, which is generated at
# build time from 7-Mac/Info.plist plus the INFOPLIST_KEY_* settings -- so
# checking the built bundle is the only check worth making.
plist="$APP/Contents/Info.plist"
handler() {  # handler <uti> -> the rank we claim for it, or "none"
    /usr/libexec/PlistBuddy -c 'Print :CFBundleDocumentTypes' "$plist" 2>/dev/null \
        | awk -v uti="$1" '
            /^ *Dict \{/ { rank = ""; found = 0 }
            $1 == "LSHandlerRank" { rank = $3 }
            $1 == uti { found = 1 }
            /^ *\}/ && found && rank { print rank; exit }
          ' | head -1
}
check "we own .7z"                 "Owner"     "$(handler org.7-zip.7-zip-archive)"
check "we own .rar"                "Owner"     "$(handler com.rarlab.rar-archive)"
# Archive Utility already opens .zip; taking it over is the user's decision,
# not ours to make at install time.
check "we are only an alternative for .zip" \
                                   "Alternate" "$(handler public.zip-archive)"
check "the imported types are declared" \
      "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDocumentTypes' "$plist" | grep -c 'LSHandlerRank = Owner')" \
      "$(/usr/libexec/PlistBuddy -c 'Print :UTImportedTypeDeclarations' "$plist" | grep -c 'UTTypeIdentifier')"
check "both services are declared" "extractArchives compressItems" \
      "$(/usr/libexec/PlistBuddy -c 'Print :NSServices' "$plist" | awk '$1 == "NSMessage" { printf "%s ", $3 }' | sed 's/ $//')"

printf '\nsandbox\n'
# Roadmap risk 6, restated for M2: extracting means writing, so the app now
# asks for read-write and for app-scoped bookmarks. Those two and no more --
# in particular no disable-library-validation, which embedding the engine has
# never needed.
# get-task-allow is added by local development signing, not by us, and is
# absent from a Developer ID build; it says nothing about what we asked for.
entitlements=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null \
               | plutil -convert json -o - - \
               | python3 -c 'import json, sys
keys = sorted(k for k in json.load(sys.stdin) if k != "com.apple.security.get-task-allow")
print(" ".join(keys))')
check "exactly the entitlements we mean to ship" \
      "com.apple.security.app-sandbox com.apple.security.files.bookmarks.app-scope com.apple.security.files.downloads.read-write com.apple.security.files.user-selected.read-write" \
      "$entitlements"
check "Info.plist is not also copied in as a resource" \
      "" "$(find "$APP/Contents/Resources" -name 'Info.plist' -o -name '*.entitlements' 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"

printf '\nquick look\n'
# M5: the archive previews and thumbnails the Finder shows, from extensions
# that link the same embedded framework rather than carrying their own.
plugins="$APP/Contents/PlugIns"
extension_point() {  # extension_point <appex> -> its NSExtensionPointIdentifier
    /usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' \
        "$plugins/$1.appex/Contents/Info.plist" 2>/dev/null
}
check "the preview extension is embedded"   "com.apple.quicklook.preview"   "$(extension_point 7-MacPreview)"
check "the thumbnail extension is embedded" "com.apple.quicklook.thumbnail" "$(extension_point 7-MacThumbnail)"
check "both extensions are signed and sandboxed" "2" "$(for x in 7-MacPreview 7-MacThumbnail; do
        codesign -d --entitlements - --xml "$plugins/$x.appex" 2>/dev/null \
            | plutil -convert json -o - - \
            | python3 -c 'import json, sys; print(json.load(sys.stdin).get("com.apple.security.app-sandbox"))'
    done | grep -c True)"
check "the extensions use the app's framework, not a copy" "" \
      "$(find "$plugins" -name 'SevenZipKit.framework' | tr '\n' ' ' | sed 's/ $//')"

printf '\nlocalization\n'
check "Italian ships" "yes" "$([ -f "$APP/Contents/Resources/it.lproj/Localizable.strings" ] && echo yes || echo no)"

printf '\nunit tests\n'
# The checks above say the package is put together correctly. These say the
# engine behaves: round trips through every writable format, encrypted and
# split archives, partial extraction, cancellation.
if xcodebuild test -project "$REPO_ROOT/7-Mac.xcodeproj" -scheme 7-Mac \
        -configuration Debug -destination 'platform=macOS' \
        -derivedDataPath "$WORK/dd" >"$WORK/test.log" 2>&1; then
    printf '  ok    %s\n' "$(grep -oE 'Executed [0-9]+ tests, with [0-9]+ failures' "$WORK/test.log" | tail -1)"
    pass=$((pass + 1))
else
    printf '  FAIL  unit tests\n'
    grep -E "error:|failed" "$WORK/test.log" | head -20
    fail=$((fail + 1))
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
