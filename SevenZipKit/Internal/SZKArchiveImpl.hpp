//
//  SZKArchiveImpl.hpp
//  SevenZipKit
//
//  What an open szk::Archive holds. Shared by the two translation units that
//  need to reach the engine's own objects -- reading (SZKArchiveCore.cpp) and
//  rewriting (SZKUpdateCore.cpp). Includes 7-Zip headers, so it must never be
//  included from Objective-C++.
//

#ifndef SZKArchiveImpl_hpp
#define SZKArchiveImpl_hpp

#include "Common/MyWindows.h"

#include "7zip/UI/Common/OpenArchive.h"

#include "SZKArchiveCore.hpp"

namespace szk {

class Archive::Impl {
public:
    CArchiveLink link;
};

}  // namespace szk

#endif /* SZKArchiveImpl_hpp */
