//
//  SZKArchiveCore.hpp
//  SevenZipKit
//
//  Opening an archive and reading what is in it.
//
//  Like SZKEngineCore.hpp, this exposes standard C++ only: the 7-Zip COM
//  headers stay inside the .cpp. Text is UTF-32LE bytes, decoded by the
//  Objective-C layer.
//

#ifndef SZKArchiveCore_hpp
#define SZKArchiveCore_hpp

#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include "SZKEngineCore.hpp"

namespace szk {

enum class Status {
    ok,
    cancelled,
    passwordRequired,   ///< encrypted, and no password was supplied
    passwordWrong,      ///< a password was supplied and did not work
    notAnArchive,       ///< no handler recognised the file
    unreadable,         ///< the file could not be opened or read
    damaged,            ///< a handler recognised it but the data is broken
    unsupported,        ///< recognised, but this build cannot process it
    failed              ///< anything else; `message` carries the detail
};

struct Result {
    Status status = Status::ok;
    std::string message;   ///< UTF-8, engine-supplied, may be empty

    bool ok() const { return status == Status::ok; }
};

/// One entry inside an archive. The `has*` flags matter: plenty of formats
/// leave timestamps, CRCs or sizes undefined, and zero is a real value.
struct EntryInfo {
    std::uint32_t index = 0;
    Text path;                      ///< as stored, '/'-separated
    bool isDirectory = false;
    bool isSymbolicLink = false;
    bool isEncrypted = false;

    bool hasSize = false;
    std::uint64_t size = 0;
    bool hasPackedSize = false;
    std::uint64_t packedSize = 0;
    bool hasCRC = false;
    std::uint32_t crc = 0;

    /// Nanoseconds since 1970. Negative means before 1970, which is legal.
    bool hasModified = false;
    std::int64_t modified = 0;
    bool hasCreated = false;
    std::int64_t created = 0;
    bool hasAccessed = false;
    std::int64_t accessed = 0;

    /// Windows attribute word. 7-Zip stores POSIX mode in its high 16 bits
    /// when FILE_ATTRIBUTE_UNIX_EXTENSION is set; `posixMode` unpacks that.
    bool hasAttributes = false;
    std::uint32_t attributes = 0;
    bool hasPosixMode = false;
    std::uint32_t posixMode = 0;

    Text method;                    ///< e.g. "LZMA2:24", may be empty
};

struct ArchiveInfo {
    Text formatName;
    std::uint32_t formatIndex = 0;
    bool hasPhysicalSize = false;
    std::uint64_t physicalSize = 0;
    /// The entry list itself is encrypted: opening needed a password.
    bool headerEncrypted = false;
    bool readOnly = false;
    /// Number of volume files, 1 for an ordinary archive. This counts the
    /// volumes the engine actually opened, which for a split set is every
    /// volume it had to read to build the entry list.
    std::uint32_t volumeCount = 1;
    /// The additional volumes, if any: the path passed to Open is not repeated.
    std::vector<Text> volumePaths;
};

/// Asked for a password. Return false to cancel the operation.
/// The string is UTF-8.
using PasswordProvider = std::function<bool(std::string &password)>;

/// Called while opening. Return false to cancel.
using OpenProgressHandler = std::function<bool(std::uint64_t files, std::uint64_t bytes)>;

/// Where extracted entries land relative to the destination directory.
enum class PathPolicy {
    fullPaths,   ///< keep the archive's directory structure
    flatten      ///< drop directories, write every file into the destination
};

/// What to do when a file is already there.
enum class OverwritePolicy {
    ask,             ///< call the OverwriteHandler
    overwrite,
    skip,
    autoRename,      ///< rename the incoming file
    renameExisting   ///< rename what is already on disk
};

/// One collision, handed to the OverwriteHandler.
struct OverwriteRequest {
    Text existingPath;
    bool hasExistingSize = false;
    std::uint64_t existingSize = 0;
    bool hasExistingModified = false;
    std::int64_t existingModified = 0;

    Text incomingPath;
    bool hasIncomingSize = false;
    std::uint64_t incomingSize = 0;
    bool hasIncomingModified = false;
    std::int64_t incomingModified = 0;
};

enum class OverwriteDecision {
    overwrite,
    overwriteAll,
    skip,
    skipAll,
    autoRename,
    cancel
};

/// Answers a collision. Only called when the policy is `ask`.
using OverwriteHandler = std::function<OverwriteDecision(const OverwriteRequest &)>;

/// How far along an operation is.
struct Progress {
    /// Total bytes the engine expects to process; 0 until it knows.
    std::uint64_t totalBytes = 0;
    std::uint64_t completedBytes = 0;
    /// Entry being worked on right now; empty between entries.
    Text currentPath;
    bool currentIsDirectory = false;
};

/// Called as work proceeds, on the calling thread. Return false to cancel:
/// the engine unwinds cooperatively and the operation reports Status::cancelled.
using ProgressHandler = std::function<bool(const Progress &)>;

/// What went wrong with one entry, when the operation as a whole carried on.
struct EntryFailure {
    Text path;
    Status status = Status::failed;
    std::string message;
};

struct ExtractOptions {
    /// UTF-8 path of the directory to write into. Created if missing.
    std::string destinationDirectory;
    PathPolicy paths = PathPolicy::fullPaths;
    OverwritePolicy overwrite = OverwritePolicy::autoRename;
    /// Decode and verify everything, write nothing. This is `test`.
    bool testOnly = false;
};

struct ExtractOutcome {
    /// Files and folders actually written (or verified, when testing).
    std::uint64_t files = 0;
    std::uint64_t folders = 0;
    /// Bytes of those files.
    std::uint64_t bytes = 0;
    /// Bytes the engine decoded, which for a partial extract from a solid
    /// archive is larger: it has to decode a whole block to reach one entry.
    /// This is the figure progress reporting counts against.
    std::uint64_t bytesProcessed = 0;
    std::vector<EntryFailure> failures;
};

/// An open archive. Non-copyable, and not safe to use from two threads at once
/// -- 7-Zip handlers keep mutable state on the stream.
class Archive {
public:
    /// Opens `path`. `password` may be empty, in which case an encrypted
    /// archive comes back as Status::passwordRequired.
    static std::unique_ptr<Archive> Open(const std::string &path,
                                         const PasswordProvider &password,
                                         const OpenProgressHandler &progress,
                                         Result &result);

    ~Archive();

    Archive(const Archive &) = delete;
    Archive &operator=(const Archive &) = delete;

    const ArchiveInfo &info() const { return info_; }

    /// Every entry, in the archive's own order. Read once on open.
    const std::vector<EntryInfo> &entries() const { return entries_; }

    /// Extracts `indices`, or everything when `indices` is empty. Indices are
    /// positions in `entries()`.
    ///
    /// Partial extraction goes through the engine's own index list rather than
    /// a name filter, so selecting three files out of forty thousand costs
    /// three files' worth of work.
    Result Extract(const std::vector<std::uint32_t> &indices,
                   const ExtractOptions &options,
                   const ProgressHandler &progress,
                   const PasswordProvider &password,
                   const OverwriteHandler &overwrite,
                   ExtractOutcome &outcome);

    /// Decodes and verifies without writing anything.
    Result Test(const std::vector<std::uint32_t> &indices,
                const ProgressHandler &progress,
                const PasswordProvider &password,
                ExtractOutcome &outcome);

private:
    class Impl;
    explicit Archive(std::unique_ptr<Impl> impl);

    std::unique_ptr<Impl> impl_;
    ArchiveInfo info_;
    std::vector<EntryInfo> entries_;
};

}  // namespace szk

#endif /* SZKArchiveCore_hpp */
