//
//  SZKStatus.hpp
//  SevenZipKit
//
//  Turning engine HRESULTs into our Status vocabulary. Shared by the C++
//  translation units; speaks 7-Zip types, so never include it from Obj-C.
//

#ifndef SZKStatus_hpp
#define SZKStatus_hpp

#include "SZKArchiveCore.hpp"

namespace szk {

/// Maps an engine HRESULT onto a Result.
///
/// The password flags matter because 7-Zip cannot always tell a wrong password
/// from corrupt data -- with an encrypted header the two look identical. What
/// it can tell us is whether a password was involved, and that is enough to
/// give the caller a useful answer.
Result ResultFromHRESULT(HRESULT hr, bool passwordWasAsked, bool passwordWasSupplied,
                         bool passwordUnavailable);

}  // namespace szk

#endif /* SZKStatus_hpp */
