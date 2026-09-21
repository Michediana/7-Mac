//
//  SZKUpdateCore.hpp
//  SevenZipKit
//
//  Creating archives. Standard C++ only; see SZKEngineCore.hpp for why.
//

#ifndef SZKUpdateCore_hpp
#define SZKUpdateCore_hpp

#include <cstdint>
#include <string>
#include <vector>

#include "SZKArchiveCore.hpp"

namespace szk {

/// Compression effort, using 7-Zip's own scale so it can be passed straight
/// through as the `-mx` property.
enum class CompressionLevel : int {
    store   = 0,
    fastest = 1,
    fast    = 3,
    normal  = 5,
    maximum = 7,
    ultra   = 9
};

struct CreateOptions {
    /// UTF-8 path of the archive to write. Must not already exist.
    std::string archivePath;

    /// Engine format name, e.g. "7z" or "zip". Empty means: work it out from
    /// the archive's extension, which is what the engine does anyway.
    ///
    /// Only the seven writable formats will succeed; ask
    /// SZKEngine.writableFormats rather than assuming. Note that gzip, bzip2
    /// and xz are single-stream: they hold exactly one file, and handing them
    /// a directory or several inputs comes back as Status::unsupported. Wrap
    /// the input in a tar first, as `.tar.gz` does.
    std::string formatName;

    CompressionLevel level = CompressionLevel::normal;

    /// Empty for no encryption. The password never reaches a command line or
    /// the disk: it is handed to the engine through a callback.
    std::string password;

    /// 7z and zip only. With 7z this also encrypts the entry list, so the
    /// archive will not even open without the password.
    bool encryptHeader = false;

    /// Split the output into volumes of this many bytes. 0 writes one file.
    std::uint64_t volumeSize = 0;

    /// Raw `-m` properties for anything the fields above do not cover, e.g.
    /// {"m", "PPMd"} or {"s", "off"}. Applied after the fields, so these win.
    std::vector<std::pair<std::string, std::string>> methodProperties;
};

struct CreateOutcome {
    std::uint64_t files = 0;
    std::uint64_t folders = 0;
    /// Size of the finished archive, if it could be measured.
    std::uint64_t archiveSize = 0;
    std::vector<EntryFailure> failures;
};

/// Creates an archive from `inputPaths` (UTF-8 files or directories, scanned
/// recursively). Paths are stored relative to each input's parent, so adding
/// `/a/b/tree` stores `tree/...`.
Result Create(const std::vector<std::string> &inputPaths,
              const CreateOptions &options,
              const ProgressHandler &progress,
              CreateOutcome &outcome);

}  // namespace szk

#endif /* SZKUpdateCore_hpp */
