# SevenZipKit

The 7-Zip engine, compiled from the pinned upstream tarball and wrapped in an
Objective-C API. The app links this framework dynamically and never spawns a
subprocess.

## Layers

| Layer | Files | Sees 7-Zip headers |
|---|---|---|
| 7-Zip engine | `Vendor/7zip/`, built by `Scripts/build-7zip-engine.sh` into a fat `lib7zip.a` | — |
| C++ core | `Internal/SZKEngineCore.{hpp,cpp}` | yes, and only here |
| Obj-C façade | `SZKEngine.{h,mm}`, `SZKFormat.{h,mm}` | no |
| Swift | the app target | no |

The C++/Obj-C split is not stylistic. 7-Zip declares `typedef int BOOL` and the
Objective-C runtime declares `typedef bool BOOL`, so the two header sets cannot
be pulled into one translation unit. `SZKEngineCore.cpp` is the wall between
them, and it is also where the COM callback implementations
(`IArchiveExtractCallback`, `ICryptoGetTextPassword2`, `IProgress`) belong:
those are abstract C++ vtables with their own refcounting, which Swift cannot
implement even with C++ interop.

## Two things that will bite you

**The engine must be linked with `-force_load`.** 7-Zip registers its format
handlers through global constructors in `*Register.cpp`, translation units that
define no symbol anyone references. Link `lib7zip.a` the ordinary way and the
linker drops every one of them: the framework builds and links cleanly, and
then reports **zero** formats at runtime. `OTHER_LDFLAGS` carries the
`-force_load` that keeps all 60.

**Do not include `MyInitGuid.h`.** That header is what *defines* the IID and
CLSID constants, and the engine archive already contains those definitions.
Including it costs 31 duplicate symbols at link time. Declare, never define.

## Licensing

7-Zip is LGPL, so everything compiled from the upstream tarball — including
`UI/Common`, which M1 brings in — makes **this whole framework LGPL**. The app
around it is MIT.

That combination is only clean because the framework is *dynamic*: the user can
relink a different build of the engine. Linking the engine statically into
`7-Mac.app` would trigger the obligation to ship object files for relinking.
Keep the boundary where it is.

The upstream `License.txt`, `copying.txt` and `unRarLicense.txt` are copied into
`SevenZipKit.framework/Resources/` at build time and must be surfaced in the
app's credits. The unRAR clause travels with them: the code may not be used to
recreate the RAR compression algorithm.
