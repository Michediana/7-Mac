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

    /// Names left out wherever they occur, with `*` and `?` wildcards:
    /// ".DS_Store", "._*". Matched against each name, not the whole path.
    std::vector<std::string> excludedNames;

    /// Store a symbolic link as a link (the default), or follow it and store
    /// what it points to.
    bool storesSymbolicLinks = true;
    /// Store a second hard link to a file as a link rather than a copy.
    bool storesHardLinks = true;
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

// ---------------------------------------------------------------------------
// Rewriting an archive that already exists
// ---------------------------------------------------------------------------
//
// An archive is never edited where it lies. Each of these writes a complete
// new archive to `outputPath`, copying the entries that did not change as
// they are -- still compressed, where the format allows -- and leaves putting
// it in place of the original to the caller. That is what makes an edit safe
// to cancel and possible to undo: until the caller swaps the files, nothing
// the person had has been touched.

struct ModifyOptions {
    /// UTF-8 path of the new archive. Must not already exist.
    std::string outputPath;

    /// Decodes existing encrypted entries where the format has to (7z
    /// repacking a solid block that lost a member), and encrypts added ones.
    /// Empty for an archive with nothing encrypted in it.
    ///
    /// 7z keeps an encrypted entry list encrypted on its own when a password
    /// is set, so there is no header switch here.
    std::string password;
};

/// What adding does with a file whose path is already in the archive.
enum class AddPolicy {
    replace,      ///< the file on disk wins
    onlyIfNewer   ///< the file on disk wins only when its date is later
};

/// Why an archive cannot be rewritten, or an empty string when it can: the
/// format has no writer (zstd, rar…), the archive spans volumes, or it was
/// reached through another container (a dmg opened straight to its HFS).
std::string WhyNotModifiable(const Archive &archive);

/// Rewrites `archive` without the entries at `indices`. Only those: a folder
/// entry's contents are separate entries, and the caller says which it means.
Result DeleteEntries(const Archive &archive,
                     const std::vector<std::uint32_t> &indices,
                     const ModifyOptions &options,
                     const ProgressHandler &progress,
                     CreateOutcome &outcome);

/// Rewrites `archive` with the entries at the given indices under new paths
/// (UTF-8, '/'-separated, archive-relative). Nothing is recompressed: only
/// the names change. Renaming a folder means renaming every entry under it,
/// which the caller does by listing them all.
Result RenameEntries(const Archive &archive,
                     const std::vector<std::pair<std::uint32_t, std::string>> &renames,
                     const ModifyOptions &options,
                     const ProgressHandler &progress,
                     CreateOutcome &outcome);

/// Rewrites `archive` with the files and folders at `inputPaths` (UTF-8,
/// scanned recursively) added under `folderInArchive` ('/'-separated, empty
/// for the root). An input keeps its own name and loses its parents on disk,
/// as with Create.
///
/// `outcome.files` and `folders` count what was taken from disk, which with
/// `onlyIfNewer` may be less than what was offered.
Result AddFiles(const Archive &archive,
                const std::vector<std::string> &inputPaths,
                const std::string &folderInArchive,
                AddPolicy policy,
                const ModifyOptions &options,
                const ProgressHandler &progress,
                CreateOutcome &outcome);

}  // namespace szk

#endif /* SZKUpdateCore_hpp */
