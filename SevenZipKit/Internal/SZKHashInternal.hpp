//
//  SZKHashInternal.hpp
//  SevenZipKit
//
//  The piece of hashing both the disk side (SZKHashCore.cpp) and the archive
//  side (SZKArchiveCore.cpp) need: a CHashBundle that also remembers each
//  file's own digest, which upstream only keeps until the next file starts.
//  Includes 7-Zip headers; never include it from Objective-C++.
//

#ifndef SZKHashInternal_hpp
#define SZKHashInternal_hpp

#include "Common/MyWindows.h"

#include "7zip/UI/Common/HashCalc.h"

#include "SZKHashCore.hpp"

namespace szk {

/// Forwards everything to a CHashBundle, and after each file copies out the
/// per-file digests before the bundle's hashers are reset for the next.
class CCapturingHash Z7_final: public IHashCalc {
public:
    CHashBundle Bundle;
    std::vector<HashedItem> Items;

    void InitForNewFile() Z7_override { Bundle.InitForNewFile(); }
    void Update(const void *data, UInt32 size) Z7_override { Bundle.Update(data, size); }
    void SetSize(UInt64 size) Z7_override { Bundle.SetSize(size); }
    void Final(bool isDir, bool isAltStream, const UString &path) Z7_override;

    /// The engine's own names for the methods in use.
    std::vector<std::string> MethodNames() const;
    /// Bundle totals, one per method.
    std::vector<std::string> DataSums() const;
};

/// UTF-8 method names to what CHashBundle::SetMethods wants.
UStringVector HashMethodNames(const std::vector<std::string> &methods);

}  // namespace szk

#endif /* SZKHashInternal_hpp */
