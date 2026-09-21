//
//  SZKEngineCoreInternal.hpp
//  SevenZipKit
//
//  Shared between the C++ translation units only. Unlike SZKEngineCore.hpp,
//  this one does speak 7-Zip types, so it must never reach an Obj-C file.
//

#ifndef SZKEngineCoreInternal_hpp
#define SZKEngineCoreInternal_hpp

#include "SZKEngineCore.hpp"

#include "Common/MyString.h"

class CCodecs;

namespace szk {

/// The process-wide codec and handler registry, created on first use.
/// Returns nullptr if the engine failed to start.
CCodecs *SharedCodecs();

/// Converts a 7-Zip UString to the raw UTF-32LE bytes the Obj-C layer decodes.
Text TextFromUString(const UString &s);

}  // namespace szk

#endif /* SZKEngineCoreInternal_hpp */
