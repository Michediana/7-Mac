#!/bin/sh
#
# Builds the 7-Zip engine from the vendored source tarball and leaves a fat
# static library where the SevenZipKit target can link it.
#
# Driven by the "SevenZipEngine" aggregate target, but it is deliberately
# runnable by hand:
#
#     ARCHS="arm64 x86_64" SEVENZIP_ENGINE_DIR=/tmp/engine Scripts/build-7zip-engine.sh
#
# Output layout under $SEVENZIP_ENGINE_DIR:
#     src/                 extracted upstream tree (also the header search path)
#     lib/lib7zip.a        fat static library, one slice per $ARCHS
#     licenses/            upstream licence texts, copied into the framework
#     .stamp               inputs this tree was built from
#
set -eu

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(dirname -- "$SCRIPT_DIR")
. "$SCRIPT_DIR/upstream-pin.sh"

die() { printf '%s: error: %s\n' "$(basename -- "$0")" "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }

[ "${ACTION:-build}" = "clean" ] && { note "clean: nothing to do"; exit 0; }

ENGINE_DIR=${SEVENZIP_ENGINE_DIR:?SEVENZIP_ENGINE_DIR is not set}
ARCHS=${ARCHS:-$(uname -m)}
TARBALL="$REPO_ROOT/Vendor/7zip/$SEVENZIP_TARBALL"

# ---------------------------------------------------------------------------
# 1. Verify the pin. An upstream that does not match the reviewed hash is a
#    hard build failure, never a warning.
# ---------------------------------------------------------------------------
[ -f "$TARBALL" ] || die "vendored tarball missing: $TARBALL"

actual=$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)
if [ "$actual" != "$SEVENZIP_SHA256" ]; then
    die "sha256 mismatch for $SEVENZIP_TARBALL
      expected $SEVENZIP_SHA256
      actual   $actual
    The vendored tarball does not match the pin in Scripts/upstream-pin.sh."
fi

# ---------------------------------------------------------------------------
# 2. Skip the whole build when nothing that feeds it has changed. The engine
#    takes ~8 s per slice, which is cheap but not free on every incremental
#    build of the app.
# ---------------------------------------------------------------------------
DEPLOY=${MACOSX_DEPLOYMENT_TARGET:-}
STAMP="$ENGINE_DIR/.stamp"
# The bundle definition is an input too: editing it must force a rebuild.
BUNDLE_HASH=$(cat "$SCRIPT_DIR/engine/"* | shasum -a 256 | cut -d' ' -f1)
STAMP_NOW="sha=$SEVENZIP_SHA256 bundle=$BUNDLE_HASH archs=$ARCHS deploy=$DEPLOY sdk=${SDKROOT:-} v=4"

if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$STAMP_NOW" ] && [ -f "$ENGINE_DIR/lib/lib7zip.a" ]; then
    note "7-Zip $SEVENZIP_VERSION engine up to date ($ARCHS)"
    exit 0
fi

note "building 7-Zip $SEVENZIP_VERSION engine for: $ARCHS"

# ---------------------------------------------------------------------------
# 3. Extract. Always from scratch: a half-updated source tree is worse than a
#    slow build.
# ---------------------------------------------------------------------------
SRC="$ENGINE_DIR/src"
rm -rf "$ENGINE_DIR"
mkdir -p "$SRC" "$ENGINE_DIR/lib" "$ENGINE_DIR/licenses"
tar -xJf "$TARBALL" -C "$SRC"
[ -d "$SRC/CPP/7zip/Bundles/Format7zF" ] || die "unexpected tarball layout: Format7zF bundle not found"

# Our bundle sits beside upstream's own, which is how 7-Zip expects a module to
# be added. Nothing in the upstream tree is patched. See Scripts/engine/README.md.
BUNDLE="$SRC/CPP/7zip/Bundles/SevenZipKit"
mkdir -p "$BUNDLE"
cp "$SCRIPT_DIR/engine/kit_gcc.mak" \
   "$SCRIPT_DIR/engine/kit_mac_arm64.mak" \
   "$SCRIPT_DIR/engine/kit_mac_x64.mak" \
   "$SCRIPT_DIR/engine/SevenZipKitInit.cpp" "$BUNDLE/"

# ---------------------------------------------------------------------------
# 4. Build one slice per architecture with the upstream macOS makefiles, then
#    archive the objects. We build the objects the official way and archive
#    them ourselves rather than linking the shared object: the engine has to end
#    up *inside* SevenZipKit.framework, which is the single dynamic library the
#    user can swap out (see SevenZipKit/README.md on the LGPL boundary).
# ---------------------------------------------------------------------------
jobs=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
slices=""

for arch in $ARCHS; do
    case "$arch" in
        arm64)  mak=kit_mac_arm64.mak; objdir=b/m_arm64 ;;
        x86_64) mak=kit_mac_x64.mak;   objdir=b/m_x64   ;;
        *)      die "unsupported architecture: $arch" ;;
    esac

    # MY_ARCH is what the upstream makefiles feed to both the compiler and the
    # linker; overriding it on the command line is how we pin the deployment
    # target and SDK without patching upstream.
    my_arch="-arch $arch"
    [ -n "$DEPLOY" ] && my_arch="$my_arch -mmacosx-version-min=$DEPLOY"
    [ -n "${SDKROOT:-}" ] && my_arch="$my_arch -isysroot $SDKROOT"

    note "  $arch ..."
    ( cd "$BUNDLE" && make -j"$jobs" -f "$mak" MY_ARCH="$my_arch" ) >"$ENGINE_DIR/build-$arch.log" 2>&1 || {
        note "--- make failed, tail of $ENGINE_DIR/build-$arch.log ---"
        tail -40 "$ENGINE_DIR/build-$arch.log" >&2
        die "engine build failed for $arch"
    }

    slice="$ENGINE_DIR/lib/lib7zip-$arch.a"
    # "has no symbols" is expected: a few translation units are empty on macOS.
    libtool -static -o "$slice" "$BUNDLE/$objdir"/*.o 2>&1 | grep -v 'has no symbols' >&2 || true
    [ -f "$slice" ] || die "libtool produced no archive for $arch"
    slices="$slices $slice"
done

# shellcheck disable=SC2086
lipo -create $slices -output "$ENGINE_DIR/lib/lib7zip.a"

# ---------------------------------------------------------------------------
# 5. Licence texts, shipped inside the framework.
# ---------------------------------------------------------------------------
for f in "$SRC/DOC/License.txt" "$SRC/DOC/copying.txt" "$SRC/DOC/unRarLicense.txt"; do
    [ -f "$f" ] && cp "$f" "$ENGINE_DIR/licenses/"
done

printf '%s' "$STAMP_NOW" > "$STAMP"
note "engine ready: $ENGINE_DIR/lib/lib7zip.a ($(lipo -archs "$ENGINE_DIR/lib/lib7zip.a"))"
