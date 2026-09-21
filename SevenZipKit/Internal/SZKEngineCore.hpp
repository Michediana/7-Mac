//
//  SZKEngineCore.hpp
//  SevenZipKit
//
//  The C++ side of the shim: everything that touches the 7-Zip COM headers.
//
//  This header deliberately exposes nothing but standard C++ types, and the
//  matching .cpp is the only translation unit that includes 7-Zip's
//  MyWindows.h. That is not tidiness for its own sake -- 7-Zip declares
//  `typedef int BOOL` while the Objective-C runtime declares `typedef bool
//  BOOL`, so the two header sets cannot meet in one translation unit. Keeping
//  them apart here is also where the COM callback implementations live.
//
//  Text comes back as raw UTF-32LE bytes rather than as a converted string:
//  7-Zip's UString is `wchar_t`-based, 32-bit wide on macOS, and NSString
//  decodes those bytes correctly without a hand-rolled converter in between.
//

#ifndef SZKEngineCore_hpp
#define SZKEngineCore_hpp

#include <cstdint>
#include <string>
#include <vector>

namespace szk {

using Bytes = std::vector<std::uint8_t>;

/// A UTF-32LE run, as 7-Zip hands text to us.
using Text = std::vector<std::uint8_t>;

/// One registered format handler.
struct FormatInfo {
    std::uint32_t index = 0;
    Text name;
    std::vector<Text> extensions;
    /// Parallel to `extensions`; empty where the format wraps nothing.
    std::vector<Text> addedExtensions;
    bool writable = false;
    bool keepsName = false;
    bool supportsAlternateStreams = false;
    bool supportsSymbolicLinks = false;
    std::uint32_t flags = 0;
    std::vector<Bytes> signatures;
    std::uint32_t signatureOffset = 0;
};

/// Every handler the engine registers, sorted by name (7-Zip's own order).
/// Built once and cached.
const std::vector<FormatInfo> &AllFormats();

/// Upstream 7-Zip version, e.g. "26.03".
std::string UpstreamVersion();

/// Upstream release date, e.g. "2026-09-03".
std::string UpstreamDate();

}  // namespace szk

#endif /* SZKEngineCore_hpp */
