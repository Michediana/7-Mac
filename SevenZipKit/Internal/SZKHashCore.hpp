//
//  SZKHashCore.hpp
//  SevenZipKit
//
//  Checksums: of files on disk, and of the entries inside an archive.
//  Standard C++ only; see SZKEngineCore.hpp for why.
//

#ifndef SZKHashCore_hpp
#define SZKHashCore_hpp

#include <cstdint>
#include <string>
#include <vector>

#include "SZKArchiveCore.hpp"

namespace szk {

struct HashMethodInfo {
    std::string name;          ///< as the engine spells it: "SHA256", "CRC32", "BLAKE2sp"…
    unsigned digestSize = 0;   ///< bytes
};

/// Every hash the engine can compute, in its registration order.
std::vector<HashMethodInfo> HashMethods();

// HashedItem lives in SZKArchiveCore.hpp, where extraction fills it in.
// `digests` has one string per method, as 7-Zip prints them: digests of 8
// bytes or fewer (CRC32, CRC64, XXH64) as an upper-case number, longer ones
// as lower-case bytes -- the way `shasum` and friends print them.

struct HashOutcome {
    /// The methods actually used, normalised by the engine.
    std::vector<std::string> methods;
    std::vector<HashedItem> items;
    /// 7-Zip's "sum of data": one figure per method covering every file.
    std::vector<std::string> dataSums;
    std::uint64_t files = 0;
    std::uint64_t bytes = 0;
    std::vector<EntryFailure> failures;
};

/// Hashes `inputPaths` (UTF-8 files or folders, scanned recursively) with
/// `methods`. Items are named relative to each input's parent, like Create.
Result HashFiles(const std::vector<std::string> &inputPaths,
                 const std::vector<std::string> &methods,
                 const ProgressHandler &progress,
                 HashOutcome &outcome);

/// Hashes the contents of entries `indices` (all of them when empty) as they
/// decode, writing nothing. This is `Test` that also says what it saw.
Result HashEntries(Archive &archive,
                   const std::vector<std::uint32_t> &indices,
                   const std::vector<std::string> &methods,
                   const ProgressHandler &progress,
                   const PasswordProvider &password,
                   HashOutcome &outcome);

}  // namespace szk

#endif /* SZKHashCore_hpp */
