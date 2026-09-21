# Engine bundle

Copied into `CPP/7zip/Bundles/SevenZipKit/` of the extracted upstream tree by
`Scripts/build-7zip-engine.sh`, then built with the upstream makefiles. Nothing
in the upstream tree is patched — this is an additional bundle beside
`Format7zF` and `Alone2`, which is how 7-Zip expects a new module to be added.

`kit_gcc.mak` is `Bundles/Alone2/makefile.gcc` (the real `7zz`) with the console
objects removed and `DEF_FILE` set, so it links a shared object instead of an
executable. Three differences are deliberate and each cost a link failure to
find:

- **No `-DZ7_EXTERNAL_CODECS`.** `LoadCodecs.h` is explicit that standalone
  modules are built without it. With it defined, `CCodecs::Load()` goes looking
  for a `7z.so` and `Codecs/` `Formats/` folders next to the executable — which
  in a sandboxed, self-contained app can only fail. It also changes class
  layouts (`CreateCoder.h`), so the framework target must agree with it.
- **No `DllExports2.o` / `ArchiveExports.o` / `CodecExports.o`.** Upstream lets
  `UI/Console/Main.cpp` define the IID/CLSID constants; exactly one translation
  unit may. `SevenZipKitInit.cpp` takes that role, so the DLL export objects —
  which would define the same GUIDs again — stay out.
- **No `SystemInfo.o`.** Only the console's CPU banner needs it, and it pulls in
  `Add_LargePages_String` from `Bench.cpp`.

`SevenZipKitInit.cpp` also supplies `NWindows::NDLL::GetModuleDirPrefix()`.
Upstream defines it in `ArchiveCommandLine.cpp` — the CLI argument parser, which
we do not build — from `argv[0]`, which a framework does not have.
