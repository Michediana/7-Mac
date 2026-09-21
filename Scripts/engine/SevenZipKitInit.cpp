// SevenZipKitInit.cpp
//
// The one translation unit that DEFINES 7-Zip's IID/CLSID constants.
//
// Upstream gives that job to UI/Console/Main.cpp, which we do not build: this
// library has no main(). Including MyInitGuid.h turns every Z7_DEFINE_GUID
// declaration pulled in below into a definition, so exactly one TU must do it
// -- which is also why DllExports2.cpp is not in OBJS.

#include "../../../Common/MyWindows.h"
#include "../../../Common/MyInitGuid.h"

#include "../../UI/Common/ArchiveOpenCallback.h"
#include "../../UI/Common/Extract.h"
#include "../../UI/Common/HashCalc.h"
#include "../../UI/Common/IFileExtractCallback.h"
#include "../../UI/Common/LoadCodecs.h"
#include "../../UI/Common/OpenArchive.h"
#include "../../UI/Common/Update.h"
#include "../../UI/Common/UpdateCallback.h"

#include "../../Common/RegisterCodec.h"

#ifndef _WIN32

#include <dlfcn.h>

#include "../../../Common/StringConvert.h"

namespace NWindows {
namespace NDLL {

// Upstream defines this in UI/Common/ArchiveCommandLine.cpp, deriving it from
// argv[0] -- which a framework does not have, and which is why we do not build
// that file (it is the CLI argument parser). Update.cpp calls it on exactly one
// path: resolving an SFX module by bare name. SFX does not exist on macOS
// (upstream ships no 7zCon.sfx and it is out of scope), so this never runs in
// anger; it answers with the directory of our own binary, which is the closest
// honest equivalent of "next to the program".
FString GetModuleDirPrefix();
FString GetModuleDirPrefix()
{
  FString s;
  static const char anchor = 0;
  Dl_info info;
  if (dladdr(&anchor, &info) != 0 && info.dli_fname)
  {
    AString path (info.dli_fname);
    const int sep = path.ReverseFind_PathSepar();
    if (sep >= 0)
    {
      path.DeleteFrom((unsigned)(sep + 1));
      s = fas2fs(path);
    }
  }
  if (s.IsEmpty())
    s = FTEXT(".") FSTRING_PATH_SEPARATOR;
  return s;
}

}}

#endif // ! _WIN32
