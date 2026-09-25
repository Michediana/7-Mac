//
//  SZKArchiveCore.cpp
//  SevenZipKit
//
//  Opening archives, and the COM callbacks that opening needs.
//

#include "SZKArchiveCore.hpp"

#include "Common/MyWindows.h"

#include "Common/MyCom.h"
#include "Common/StringConvert.h"
#include "Common/Wildcard.h"
#include "Windows/FileDir.h"
#include "Windows/FileName.h"
#include "Windows/PropVariant.h"
#include "Windows/PropVariantConv.h"
#include "7zip/Archive/IArchive.h"
#include "7zip/UI/Common/ArchiveExtractCallback.h"
#include "7zip/UI/Common/ArchiveOpenCallback.h"
#include "7zip/UI/Common/LoadCodecs.h"
#include "7zip/UI/Common/OpenArchive.h"
#include "7zip/UI/Common/Property.h"

#include <cstdio>
#include <map>

#include "SZKArchiveImpl.hpp"
#include "SZKEngineCoreInternal.hpp"
#include "SZKStatus.hpp"

namespace szk {
namespace {

// ---------------------------------------------------------------------------
// PROPVARIANT readers
// ---------------------------------------------------------------------------

using NWindows::NCOM::CPropVariant;

bool ReadBool(IInArchive *archive, UInt32 index, PROPID propID, bool &value)
{
    CPropVariant prop;
    if (archive->GetProperty(index, propID, &prop) != S_OK || prop.vt != VT_BOOL) {
        return false;
    }
    value = (prop.boolVal != VARIANT_FALSE);
    return true;
}

bool ReadUInt64(IInArchive *archive, UInt32 index, PROPID propID, std::uint64_t &value)
{
    CPropVariant prop;
    if (archive->GetProperty(index, propID, &prop) != S_OK) {
        return false;
    }
    UInt64 converted = 0;
    if (!ConvertPropVariantToUInt64(prop, converted)) {
        return false;
    }
    value = converted;
    return true;
}

bool ReadUInt32(IInArchive *archive, UInt32 index, PROPID propID, std::uint32_t &value)
{
    CPropVariant prop;
    if (archive->GetProperty(index, propID, &prop) != S_OK || prop.vt != VT_UI4) {
        return false;
    }
    value = prop.ulVal;
    return true;
}

/// FILETIME counts 100 ns ticks from 1601-01-01; we answer in nanoseconds from
/// 1970-01-01, which is what Foundation wants.
constexpr std::int64_t kTicksBetween1601And1970 = 116444736000000000LL;

bool FileTimeToUnixNanoseconds(const FILETIME &time, std::int64_t &nanoseconds)
{
    const std::int64_t ticks =
        (static_cast<std::int64_t>(time.dwHighDateTime) << 32) |
        static_cast<std::int64_t>(time.dwLowDateTime);
    if (ticks == 0) {
        return false;  // 7-Zip uses an all-zero FILETIME for "not set".
    }
    nanoseconds = (ticks - kTicksBetween1601And1970) * 100;
    return true;
}

bool ReadTime(IInArchive *archive, UInt32 index, PROPID propID, std::int64_t &nanoseconds)
{
    CPropVariant prop;
    if (archive->GetProperty(index, propID, &prop) != S_OK || prop.vt != VT_FILETIME) {
        return false;
    }
    return FileTimeToUnixNanoseconds(prop.filetime, nanoseconds);
}

/// Maps a per-entry extraction result. `kDataError` on an encrypted entry is
/// how 7-Zip says "wrong password": with the data itself encrypted it cannot
/// distinguish a bad key from corruption, so the encrypted flag is the signal.
Status StatusFromOperationResult(Int32 opRes, bool encrypted)
{
    namespace Op = NArchive::NExtract::NOperationResult;
    switch (opRes) {
        case Op::kOK:                    return Status::ok;
        case Op::kUnsupportedMethod:     return Status::unsupported;
        case Op::kDataError:             return encrypted ? Status::passwordWrong : Status::damaged;
        case Op::kCRCError:              return encrypted ? Status::passwordWrong : Status::damaged;
        case Op::kUnavailable:
        case Op::kUnexpectedEnd:
        case Op::kDataAfterEnd:
        case Op::kIsNotArc:
        case Op::kHeadersError:          return Status::damaged;
        case Op::kWrongPassword:         return Status::passwordWrong;
        default:                         return Status::failed;
    }
}

const char *DescribeOperationResult(Int32 opRes)
{
    namespace Op = NArchive::NExtract::NOperationResult;
    switch (opRes) {
        case Op::kOK:                return "";
        case Op::kUnsupportedMethod: return "unsupported compression method";
        case Op::kDataError:         return "data error";
        case Op::kCRCError:          return "checksum mismatch";
        case Op::kUnavailable:       return "data unavailable";
        case Op::kUnexpectedEnd:     return "unexpected end of archive";
        case Op::kDataAfterEnd:      return "unexpected data after the end of the archive";
        case Op::kIsNotArc:          return "not an archive";
        case Op::kHeadersError:      return "damaged headers";
        case Op::kWrongPassword:     return "wrong password";
        default:                     return "extraction failed";
    }
}

Text ReadText(IInArchive *archive, UInt32 index, PROPID propID)
{
    CPropVariant prop;
    if (archive->GetProperty(index, propID, &prop) != S_OK || prop.vt != VT_BSTR) {
        return {};
    }
    const UString value (prop.bstrVal);
    return TextFromUString(value);
}

}  // namespace

// ---------------------------------------------------------------------------
// Mapping engine results onto our vocabulary
// ---------------------------------------------------------------------------

Result ResultFromHRESULT(HRESULT hr, bool passwordWasAsked, bool passwordWasSupplied,
                         bool passwordUnavailable)
{
    Result result;
    if (hr == S_OK) {
        return result;
    }

    if (hr == E_ABORT) {
        // We abort for two different reasons, and callers need to tell them
        // apart: nobody could supply a password, versus somebody declined to.
        result.status = passwordUnavailable ? Status::passwordRequired : Status::cancelled;
        return result;
    }

    // 7-Zip reports a bad password the same way it reports corrupt data,
    // because with an encrypted header it genuinely cannot tell the two apart.
    // What it *can* tell us is whether a password was involved at all.
    if (hr == S_FALSE || hr == E_FAIL) {
        if (passwordWasAsked) {
            result.status = passwordWasSupplied ? Status::passwordWrong
                                                : Status::passwordRequired;
            return result;
        }
        result.status = (hr == S_FALSE) ? Status::notAnArchive : Status::damaged;
        return result;
    }

    if (hr == E_NOTIMPL) {
        result.status = Status::unsupported;
        return result;
    }
    if (hr == E_INVALIDARG) {
        // The handler refused the job as specified. In practice this is
        // almost always a single-stream format -- gzip, bzip2, xz -- being
        // handed more than one file.
        result.status = Status::unsupported;
        result.message = "the format rejected these options";
        return result;
    }
    if (hr == E_OUTOFMEMORY) {
        result.status = Status::failed;
        result.message = "out of memory";
        return result;
    }

    result.status = Status::failed;
    char buffer[32];
    std::snprintf(buffer, sizeof(buffer), "engine error 0x%08X", static_cast<unsigned>(hr));
    result.message = buffer;
    return result;
}

namespace {

// ---------------------------------------------------------------------------
// Open callback
// ---------------------------------------------------------------------------

/// Bridges 7-Zip's open-time callbacks to our std::function handlers.
///
/// IOpenCallbackUI is a plain virtual interface, not a COM one: CArchiveLink
/// wraps it in its own COpenCallbackImp, which is what handles multi-volume
/// sets and hands the password down.
class COpenCallback Z7_final: public IOpenCallbackUI {
public:
    COpenCallback(const PasswordProvider &password, const OpenProgressHandler &progress)
        : password_(password), progress_(progress) {}

    bool PasswordWasAsked = false;
    bool PasswordWasSupplied = false;
    /// Asked for a password with no provider wired up at all.
    bool PasswordUnavailable = false;

    HRESULT Open_CheckBreak() override
    {
        return cancelled_ ? E_ABORT : S_OK;
    }

    HRESULT Open_SetTotal(const UInt64 *files, const UInt64 *bytes) override
    {
        if (files) { totalFiles_ = *files; }
        if (bytes) { totalBytes_ = *bytes; }
        return Open_CheckBreak();
    }

    HRESULT Open_SetCompleted(const UInt64 *files, const UInt64 *bytes) override
    {
        if (!cancelled_ && progress_) {
            const std::uint64_t f = files ? *files : totalFiles_;
            const std::uint64_t b = bytes ? *bytes : totalBytes_;
            if (!progress_(f, b)) {
                cancelled_ = true;
            }
        }
        return Open_CheckBreak();
    }

    HRESULT Open_Finished() override { return S_OK; }

    HRESULT Open_CryptoGetTextPassword(BSTR *password) override
    {
        PasswordWasAsked = true;
        if (!password_) {
            PasswordUnavailable = true;
            return E_ABORT;
        }
        std::string supplied;
        if (!password_(supplied)) {
            cancelled_ = true;
            return E_ABORT;
        }
        PasswordWasSupplied = true;
        const UString wide = GetUnicodeString(supplied.c_str(), CP_UTF8);
        return StringToBstr(wide, password);
    }

private:
    const PasswordProvider &password_;
    const OpenProgressHandler &progress_;
    std::uint64_t totalFiles_ = 0;
    std::uint64_t totalBytes_ = 0;
    bool cancelled_ = false;
};

}  // namespace

// ---------------------------------------------------------------------------
// Archive
// ---------------------------------------------------------------------------

Archive::Archive(std::unique_ptr<Impl> impl) : impl_(std::move(impl)) {}

Archive::~Archive() = default;

std::unique_ptr<Archive> Archive::Open(const std::string &path,
                                       const PasswordProvider &password,
                                       const OpenProgressHandler &progress,
                                       Result &result)
{
    CCodecs *codecs = SharedCodecs();
    if (!codecs) {
        result.status = Status::failed;
        result.message = "the engine failed to start";
        return nullptr;
    }

    auto impl = std::make_unique<Impl>();
    COpenCallback callback (password, progress);

    CObjectVector<COpenType> types;   // empty: let the engine sniff the format
    CIntVector excludedFormats;
    // COpenOptions leaves `props` uninitialised -- its constructor sets every
    // other pointer to NULL but not this one, and every upstream caller
    // assigns it. Reading it unset is a crash inside Open, not a null check.
    const CObjectVector<CProperty> noProperties;

    COpenOptions options;
    options.props = &noProperties;
    options.codecs = codecs;
    options.types = &types;
    options.excludedFormats = &excludedFormats;
    options.stdInMode = false;
    options.stream = nullptr;
    options.filePath = GetUnicodeString(path.c_str(), CP_UTF8);

    const HRESULT hr = impl->link.Open_Strict(options, &callback);
    if (hr != S_OK) {
        result = ResultFromHRESULT(hr, callback.PasswordWasAsked, callback.PasswordWasSupplied,
                                   callback.PasswordUnavailable);
        return nullptr;
    }
    return Finish(std::move(impl),
                  callback.PasswordWasAsked && callback.PasswordWasSupplied, result);
}

std::unique_ptr<Archive> Archive::OpenEntry(std::uint32_t index,
                                            const PasswordProvider &password,
                                            Result &result)
{
    CCodecs *codecs = SharedCodecs();
    const CArc *arc = impl_->link.GetArc();
    if (!codecs || !arc || index >= entries_.size()) {
        result.status = Status::failed;
        result.message = "no such entry";
        return nullptr;
    }

    // The same three steps CArchiveLink::Open takes for a kpidMainSubfile, but
    // for an entry of our choosing. Each can fail for a perfectly ordinary
    // reason -- the handler has no GetStream, or its stream only reads
    // forwards -- and every one of them means "extract it instead".
    CMyComPtr<IInArchiveGetStream> getStream;
    if (arc->Archive->QueryInterface(IID_IInArchiveGetStream, (void **)&getStream) != S_OK
        || !getStream) {
        result.status = Status::unsupported;
        result.message = "this format cannot open an entry in place";
        return nullptr;
    }
    CMyComPtr<ISequentialInStream> sequential;
    if (getStream->GetStream(index, &sequential) != S_OK || !sequential) {
        result.status = Status::unsupported;
        result.message = "this entry cannot be opened in place";
        return nullptr;
    }
    CMyComPtr<IInStream> stream;
    if (sequential.QueryInterface(IID_IInStream, &stream) != S_OK || !stream) {
        result.status = Status::unsupported;
        result.message = "this entry can only be read from start to end";
        return nullptr;
    }

    UString itemPath;
    arc->GetItem_Path(index, itemPath);

    auto impl = std::make_unique<Impl>();
    const OpenProgressHandler noProgress;
    COpenCallback callback (password, noProgress);

    CObjectVector<COpenType> types;
    CIntVector excludedFormats;
    const CObjectVector<CProperty> noProperties;   // see Open: must be set

    COpenOptions options;
    options.props = &noProperties;
    options.codecs = codecs;
    options.types = &types;
    options.excludedFormats = &excludedFormats;
    options.stdInMode = false;
    options.stream = stream;
    options.filePath = itemPath;

    const HRESULT hr = impl->link.Open_Strict(options, &callback);
    if (hr != S_OK) {
        result = ResultFromHRESULT(hr, callback.PasswordWasAsked, callback.PasswordWasSupplied,
                                   callback.PasswordUnavailable);
        return nullptr;
    }
    return Finish(std::move(impl),
                  callback.PasswordWasAsked && callback.PasswordWasSupplied, result);
}

std::unique_ptr<Archive> Archive::Finish(std::unique_ptr<Impl> impl, bool headerEncrypted,
                                         Result &result)
{
    CCodecs *codecs = SharedCodecs();
    std::unique_ptr<Archive> archive (new Archive(std::move(impl)));
    const CArc *arc = archive->impl_->link.GetArc();
    IInArchive *inArchive = arc->Archive;

    // --- archive-level facts
    ArchiveInfo &info = archive->info_;
    if (arc->FormatIndex >= 0) {
        info.formatIndex = static_cast<std::uint32_t>(arc->FormatIndex);
        info.formatName = TextFromUString(codecs->Formats[(unsigned)arc->FormatIndex].Name);
    }
    info.hasPhysicalSize = arc->PhySize_Defined;
    info.physicalSize = arc->PhySize;
    info.readOnly = arc->IsReadOnly;
    info.headerEncrypted = headerEncrypted;
    // VolumePaths holds the *additional* volumes the engine opened; the one we
    // were handed is not in it (upstream comments its Add out). So a plain
    // archive gives an empty list, and a 4-part set gives three.
    const CArchiveLink &link = archive->impl_->link;
    info.volumeCount = link.VolumePaths.Size() + 1;
    FOR_VECTOR (v, link.VolumePaths) {
        info.volumePaths.push_back(TextFromUString(link.VolumePaths[v]));
    }

    // --- entries
    UInt32 count = 0;
    if (inArchive->GetNumberOfItems(&count) != S_OK) {
        result.status = Status::damaged;
        result.message = "the archive would not report its contents";
        return nullptr;
    }

    archive->entries_.reserve(count);
    for (UInt32 i = 0; i < count; i++) {
        EntryInfo entry;
        entry.index = i;

        UString itemPath;
        if (arc->GetItem_Path(i, itemPath) == S_OK) {
            entry.path = TextFromUString(itemPath);
        }

        ReadBool(inArchive, i, kpidIsDir, entry.isDirectory);
        ReadBool(inArchive, i, kpidEncrypted, entry.isEncrypted);

        entry.hasSize = ReadUInt64(inArchive, i, kpidSize, entry.size);
        entry.hasPackedSize = ReadUInt64(inArchive, i, kpidPackSize, entry.packedSize);
        entry.hasCRC = ReadUInt32(inArchive, i, kpidCRC, entry.crc);
        entry.hasModified = ReadTime(inArchive, i, kpidMTime, entry.modified);
        entry.hasCreated = ReadTime(inArchive, i, kpidCTime, entry.created);
        entry.hasAccessed = ReadTime(inArchive, i, kpidATime, entry.accessed);
        entry.hasAttributes = ReadUInt32(inArchive, i, kpidAttrib, entry.attributes);
        entry.method = ReadText(inArchive, i, kpidMethod);

        // 7-Zip stows the POSIX mode in the top 16 bits of the Windows
        // attribute word, flagged by FILE_ATTRIBUTE_UNIX_EXTENSION. That is
        // where the symlink bit lives on archives written by Unix tools.
        if (entry.hasAttributes && (entry.attributes & FILE_ATTRIBUTE_UNIX_EXTENSION) != 0) {
            entry.hasPosixMode = true;
            entry.posixMode = entry.attributes >> 16;
            entry.isSymbolicLink = ((entry.posixMode & 0xF000) == 0xA000);  // S_IFLNK
        } else if (entry.hasAttributes) {
            entry.isSymbolicLink =
                (entry.attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0;
        }

        archive->entries_.push_back(std::move(entry));
    }

    return archive;
}

// ---------------------------------------------------------------------------
// Extraction callback
// ---------------------------------------------------------------------------

namespace {

/// Bridges CArchiveExtractCallback's questions to our std::function handlers.
///
/// CArchiveExtractCallback (3242 lines of upstream) does the actual work:
/// building output paths, applying attributes and timestamps, restoring
/// symlinks and hard links. This object only answers it.
class CExtractCallback Z7_final:
    public IFolderArchiveExtractCallback,
    public IFolderArchiveExtractCallback2,
    public ICryptoGetTextPassword,
    public CMyUnknownImp
{
    Z7_COM_QI_BEGIN2(IFolderArchiveExtractCallback)
    Z7_COM_QI_ENTRY(IFolderArchiveExtractCallback2)
    Z7_COM_QI_ENTRY(ICryptoGetTextPassword)
    Z7_COM_QI_END
    Z7_COM_ADDREF_RELEASE

    Z7_IFACE_COM7_IMP(IProgress)
    Z7_IFACE_COM7_IMP(IFolderArchiveExtractCallback)
    Z7_IFACE_COM7_IMP(IFolderArchiveExtractCallback2)
    Z7_IFACE_COM7_IMP(ICryptoGetTextPassword)

public:
    CExtractCallback(const ProgressHandler &progress,
                     const PasswordProvider &password,
                     const OverwriteHandler &overwrite,
                     const std::map<Text, std::uint64_t> &sizeByPath,
                     ExtractOutcome &outcome)
        : progress_(progress), password_(password), overwrite_(overwrite),
          sizeByPath_(sizeByPath), outcome_(outcome) {}

    bool Cancelled = false;
    bool PasswordWasAsked = false;
    bool PasswordWasSupplied = false;
    bool PasswordUnavailable = false;

private:
    HRESULT CheckBreak() const { return Cancelled ? E_ABORT : S_OK; }

    /// Reports the current state, letting the handler cancel.
    HRESULT Report()
    {
        if (Cancelled) {
            return E_ABORT;
        }
        if (progress_ && !progress_(state_)) {
            Cancelled = true;
            return E_ABORT;
        }
        return S_OK;
    }

    const ProgressHandler &progress_;
    const PasswordProvider &password_;
    const OverwriteHandler &overwrite_;
    const std::map<Text, std::uint64_t> &sizeByPath_;
    ExtractOutcome &outcome_;

    Progress state_;
    /// NAskMode for the entry in flight. kSkip marks an entry the engine is
    /// only decoding on the way to one we asked for.
    Int32 askMode_ = NArchive::NExtract::NAskMode::kExtract;
    /// Sticky answers from "…to all" decisions.
    bool overwriteAll_ = false;
    bool skipAll_ = false;
};

Z7_COM7F_IMF(CExtractCallback::SetTotal(UInt64 total))
{
    state_.totalBytes = total;
    return Report();
}

Z7_COM7F_IMF(CExtractCallback::SetCompleted(const UInt64 *completeValue))
{
    if (completeValue) {
        state_.completedBytes = *completeValue;
    }
    return Report();
}

Z7_COM7F_IMF(CExtractCallback::AskOverwrite(
    const wchar_t *existName, const FILETIME *existTime, const UInt64 *existSize,
    const wchar_t *newName, const FILETIME *newTime, const UInt64 *newSize,
    Int32 *answer))
{
    RINOK(CheckBreak())

    if (overwriteAll_) { *answer = NOverwriteAnswer::kYes; return S_OK; }
    if (skipAll_)      { *answer = NOverwriteAnswer::kNo;  return S_OK; }

    if (!overwrite_) {
        // No handler wired up and the policy still said ask: the safe reading
        // of "ask" with nobody to ask is "do not destroy anything".
        *answer = NOverwriteAnswer::kNo;
        return S_OK;
    }

    OverwriteRequest request;
    request.existingPath = TextFromUString(UString(existName));
    request.incomingPath = TextFromUString(UString(newName));
    if (existSize) { request.hasExistingSize = true; request.existingSize = *existSize; }
    if (newSize)   { request.hasIncomingSize = true; request.incomingSize = *newSize; }
    if (existTime) {
        request.hasExistingModified = FileTimeToUnixNanoseconds(*existTime, request.existingModified);
    }
    if (newTime) {
        request.hasIncomingModified = FileTimeToUnixNanoseconds(*newTime, request.incomingModified);
    }

    switch (overwrite_(request)) {
        case OverwriteDecision::overwrite:    *answer = NOverwriteAnswer::kYes; break;
        case OverwriteDecision::overwriteAll: overwriteAll_ = true;
                                              *answer = NOverwriteAnswer::kYes; break;
        case OverwriteDecision::skip:         *answer = NOverwriteAnswer::kNo; break;
        case OverwriteDecision::skipAll:      skipAll_ = true;
                                              *answer = NOverwriteAnswer::kNo; break;
        case OverwriteDecision::autoRename:   *answer = NOverwriteAnswer::kAutoRename; break;
        case OverwriteDecision::cancel:
            Cancelled = true;
            return E_ABORT;
    }
    return S_OK;
}

Z7_COM7F_IMF(CExtractCallback::PrepareOperation(const wchar_t *name, Int32 isFolder,
                                                Int32 askExtractMode, const UInt64 *position))
{
    UNUSED_VAR(position)
    askMode_ = askExtractMode;
    state_.currentPath = name ? TextFromUString(UString(name)) : Text();
    state_.currentIsDirectory = (isFolder != 0);
    return Report();
}

Z7_COM7F_IMF(CExtractCallback::MessageError(const wchar_t *message))
{
    // These are filesystem-level problems -- could not create a folder, could
    // not open an output file. The engine reports them here and still returns
    // kOK from SetOperationResult, because the *decoding* worked; so this is
    // the only place they surface. The message names the path it is about, so
    // we do not attach the entry we happen to be on.
    EntryFailure failure;
    failure.status = Status::unreadable;
    if (message) {
        failure.message = UnicodeStringToMultiByte(UString(message), CP_UTF8).Ptr();
    }
    outcome_.failures.push_back(std::move(failure));
    return CheckBreak();
}

Z7_COM7F_IMF(CExtractCallback::SetOperationResult(Int32 opRes, Int32 encrypted))
{
    return ReportExtractResult(opRes, encrypted, nullptr);
}

Z7_COM7F_IMF(CExtractCallback::ReportExtractResult(Int32 opRes, Int32 encrypted,
                                                   const wchar_t *name))
{
    if (opRes == NArchive::NExtract::NOperationResult::kOK) {
        // Count only what was really written. In a solid archive the engine
        // walks every entry of a block to reach the ones that were asked for
        // and reports kOK for those too, flagged kSkip -- which is also why
        // CArchiveExtractCallback's own NumFiles overcounts a partial extract.
        if (askMode_ != NArchive::NExtract::NAskMode::kSkip) {
            if (state_.currentIsDirectory) {
                outcome_.folders++;
            } else {
                outcome_.files++;
                const auto found = sizeByPath_.find(state_.currentPath);
                if (found != sizeByPath_.end()) {
                    outcome_.bytes += found->second;
                }
            }
        }
        return CheckBreak();
    }

    EntryFailure failure;
    failure.path = name ? TextFromUString(UString(name)) : state_.currentPath;
    failure.status = StatusFromOperationResult(opRes, encrypted != 0);
    failure.message = DescribeOperationResult(opRes);
    outcome_.failures.push_back(std::move(failure));
    return CheckBreak();
}

Z7_COM7F_IMF(CExtractCallback::CryptoGetTextPassword(BSTR *password))
{
    PasswordWasAsked = true;
    if (!password_) {
        PasswordUnavailable = true;
        return E_ABORT;
    }
    std::string supplied;
    if (!password_(supplied)) {
        Cancelled = true;
        return E_ABORT;
    }
    PasswordWasSupplied = true;
    const UString wide = GetUnicodeString(supplied.c_str(), CP_UTF8);
    return StringToBstr(wide, password);
}

}  // namespace

// ---------------------------------------------------------------------------
// Archive::Extract
// ---------------------------------------------------------------------------

Result Archive::Extract(const std::vector<std::uint32_t> &indices,
                        const ExtractOptions &options,
                        const ProgressHandler &progress,
                        const PasswordProvider &password,
                        const OverwriteHandler &overwrite,
                        ExtractOutcome &outcome)
{
    Result result;

    const CArc *arc = impl_->link.GetArc();
    IInArchive *inArchive = arc->Archive;

    // PrepareOperation reports the archive-relative path, the same string
    // entries() carries, so this is enough to total the bytes we write.
    std::map<Text, std::uint64_t> sizeByPath;
    for (const EntryInfo &entry : entries_) {
        if (entry.hasSize && !entry.isDirectory) {
            sizeByPath[entry.path] = entry.size;
        }
    }

    CMyComPtr2_Create<IArchiveExtractCallback, CArchiveExtractCallback> extractor;
    auto *callbackSpec = new CExtractCallback(progress, password, overwrite, sizeByPath, outcome);
    CMyComPtr<IFolderArchiveExtractCallback> callback (callbackSpec);

    const CExtractNtOptions ntOptions;  // defaults already enable symlinks and hard links

    NExtract::NPathMode::EEnum pathMode = (options.paths == PathPolicy::flatten)
        ? NExtract::NPathMode::kNoPaths
        : NExtract::NPathMode::kFullPaths;

    NExtract::NOverwriteMode::EEnum overwriteMode;
    switch (options.overwrite) {
        case OverwritePolicy::ask:            overwriteMode = NExtract::NOverwriteMode::kAsk; break;
        case OverwritePolicy::overwrite:      overwriteMode = NExtract::NOverwriteMode::kOverwrite; break;
        case OverwritePolicy::skip:           overwriteMode = NExtract::NOverwriteMode::kSkip; break;
        case OverwritePolicy::autoRename:     overwriteMode = NExtract::NOverwriteMode::kRename; break;
        case OverwritePolicy::renameExisting: overwriteMode = NExtract::NOverwriteMode::kRenameExisting; break;
    }

    extractor->InitForMulti(false, pathMode, overwriteMode, NExtract::NZoneIdMode::kNone, false);

    FString destination;
    if (!options.testOnly) {
        destination = us2fs(GetUnicodeString(options.destinationDirectory.c_str(), CP_UTF8));
        NWindows::NFile::NName::NormalizeDirPathPrefix(destination);
        // CArchiveExtractCallback creates the archive's own subfolders but not
        // the directory we point it at; upstream's Extract() does this first.
        if (!destination.IsEmpty() && !NWindows::NFile::NDir::CreateComplexDir(destination)) {
            result.status = Status::unreadable;
            result.message = "could not create the destination directory";
            return result;
        }
    }

    // Paths are archive-relative. Asked to, strip the folders every selected
    // entry shares -- computed from the engine's own split of each path, the
    // same parts CArchiveExtractCallback compares against, so a `./` prefix
    // or a doubled slash cannot make the two disagree. An entry outside the
    // prefix would be an E_FAIL, which by construction there is none of.
    UStringVector removePathParts;
    if (options.relativeToCommonParent && !indices.empty()
        && options.paths == PathPolicy::fullPaths) {
        bool first = true;
        for (const std::uint32_t index : indices) {
            CReadArcItem item;
            if (arc->GetItem(index, item) != S_OK) {
                removePathParts.Clear();
                break;
            }
            UStringVector parent = item.PathParts;
            if (!parent.IsEmpty()) {
                parent.DeleteBack();
            }
            if (first) {
                removePathParts = parent;
                first = false;
                continue;
            }
            unsigned shared = 0;
            while (shared < removePathParts.Size() && shared < parent.Size()
                   && CompareFileNames(removePathParts[shared], parent[shared]) == 0) {
                shared++;
            }
            removePathParts.DeleteFrom(shared);
            if (removePathParts.IsEmpty()) {
                break;
            }
        }
    }
    extractor->Init(ntOptions, nullptr /* no wildcard filter: we select by index */,
                    arc, callback, false /* stdOutMode */, options.testOnly,
                    destination, removePathParts, false, arc->GetEstmatedPhySize());

    // An empty index list means "everything", which the engine spells as a
    // null pointer with a count of -1.
    const UInt32 *indexList = indices.empty() ? nullptr : indices.data();
    const UInt32 indexCount = indices.empty() ? (UInt32)(Int32)-1
                                              : static_cast<UInt32>(indices.size());

    HRESULT hr = inArchive->Extract(indexList, indexCount,
                                    options.testOnly ? 1 : 0, extractor.Interface());

    // Extract() alone does not finish the job. CloseArc() flushes the last
    // file, creates the symbolic and hard links that had to wait until their
    // targets existed, and stamps directory times. Without it symlinks land as
    // empty regular files and folder timestamps are whatever the OS left.
    CArchiveExtractCallback_Closer closer (extractor.ClsPtr());
    const HRESULT closeResult = closer.Close();
    if (hr == S_OK) {
        hr = closeResult;
    }

    outcome.bytesProcessed = extractor->UnpackSize;

    if (hr != S_OK) {
        result = ResultFromHRESULT(hr, callbackSpec->PasswordWasAsked,
                                   callbackSpec->PasswordWasSupplied,
                                   callbackSpec->PasswordUnavailable);
        return result;
    }
    if (callbackSpec->Cancelled) {
        result.status = Status::cancelled;
        return result;
    }

    // The engine can finish cleanly while individual entries failed -- a bad
    // password on one file in a zip, say. Surface that rather than hiding it
    // behind an overall S_OK.
    if (!outcome.failures.empty()) {
        result.status = outcome.failures.front().status;
        result.message = outcome.failures.front().message;
    }
    return result;
}

Result Archive::Test(const std::vector<std::uint32_t> &indices,
                     const ProgressHandler &progress,
                     const PasswordProvider &password,
                     ExtractOutcome &outcome)
{
    ExtractOptions options;
    options.testOnly = true;
    return Extract(indices, options, progress, password, nullptr, outcome);
}

}  // namespace szk
