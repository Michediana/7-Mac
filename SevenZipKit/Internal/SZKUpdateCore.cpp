//
//  SZKUpdateCore.cpp
//  SevenZipKit
//
//  Creating archives, and the COM-ish callback that creation needs.
//

#include "SZKUpdateCore.hpp"

#include <cstdio>
#include <map>

#include "Common/MyWindows.h"

#include "Common/IntToString.h"
#include "Common/StringConvert.h"
#include "Windows/FileDir.h"
#include "Windows/FileFind.h"
#include "Windows/PropVariant.h"
#include "7zip/Common/FileStreams.h"
#include "7zip/UI/Common/EnumDirItems.h"
#include "7zip/UI/Common/LoadCodecs.h"
#include "7zip/UI/Common/OpenArchive.h"
#include "7zip/UI/Common/Update.h"
#include "7zip/UI/Common/UpdateCallback.h"
#include "7zip/UI/Common/UpdatePair.h"
#include "7zip/UI/Common/UpdateProduce.h"

#include "SZKArchiveImpl.hpp"
#include "SZKEngineCoreInternal.hpp"
#include "SZKStatus.hpp"

namespace szk {
namespace {

/// Answers everything UpdateArchive asks along the way.
///
/// IUpdateCallbackUI2 is broad -- scanning, opening, per-file progress,
/// passwords, moving the finished temporary file into place. Most of it we
/// have nothing to say about, and saying S_OK is the whole implementation;
/// the handful that matter are progress, cancellation and the password.
class CUpdateCallback Z7_final: public IUpdateCallbackUI2 {
    Z7_IFACE_IMP(IUpdateCallbackUI)
    Z7_IFACE_IMP(IDirItemsCallback)
    Z7_IFACE_IMP(IUpdateCallbackUI2)

public:
    CUpdateCallback(const ProgressHandler &progress, const std::string &password,
                    CreateOutcome &outcome)
        : progress_(progress), password_(password), outcome_(outcome) {}

    bool Cancelled = false;
    /// The engine needed to decode an encrypted entry.
    bool PasswordWasAsked = false;
    /// …and we had no password to give it.
    bool PasswordUnavailable = false;

private:
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

    void RecordFailure(const FString &path, DWORD systemError, const char *what);

    const ProgressHandler &progress_;
    const std::string &password_;
    CreateOutcome &outcome_;
    Progress state_;
};

void CUpdateCallback::RecordFailure(const FString &path, DWORD systemError, const char *what)
{
    EntryFailure failure;
    failure.path = TextFromUString(fs2us(path));
    failure.status = Status::unreadable;
    char buffer[64];
    std::snprintf(buffer, sizeof(buffer), " (errno=%u)", static_cast<unsigned>(systemError));
    failure.message = std::string(what) + buffer;
    outcome_.failures.push_back(std::move(failure));
}

// --- the parts that do something -------------------------------------------

HRESULT CUpdateCallback::SetTotal(UInt64 size)
{
    state_.totalBytes = size;
    return Report();
}

HRESULT CUpdateCallback::SetCompleted(const UInt64 *completeValue)
{
    if (completeValue) {
        state_.completedBytes = *completeValue;
    }
    return Report();
}

HRESULT CUpdateCallback::CheckBreak() { return Cancelled ? E_ABORT : S_OK; }

HRESULT CUpdateCallback::GetStream(const wchar_t *name, bool isDir, bool /* isAnti */,
                                   UInt32 /* mode */)
{
    state_.currentPath = name ? TextFromUString(UString(name)) : Text();
    state_.currentIsDirectory = isDir;
    if (isDir) {
        outcome_.folders++;
    } else {
        outcome_.files++;
    }
    return Report();
}

HRESULT CUpdateCallback::CryptoGetTextPassword2(Int32 *passwordIsDefined, BSTR *password)
{
    if (password_.empty()) {
        *passwordIsDefined = BoolToInt(false);
        return StringToBstr(UString(), password);
    }
    *passwordIsDefined = BoolToInt(true);
    return StringToBstr(GetUnicodeString(password_.c_str(), CP_UTF8), password);
}

HRESULT CUpdateCallback::CryptoGetTextPassword(BSTR *password)
{
    // Asked when re-reading an existing encrypted archive we are updating.
    PasswordWasAsked = true;
    if (password_.empty()) {
        PasswordUnavailable = true;
        return E_ABORT;
    }
    return StringToBstr(GetUnicodeString(password_.c_str(), CP_UTF8), password);
}

HRESULT CUpdateCallback::OpenFileError(const FString &path, DWORD systemError)
{
    RecordFailure(path, systemError, "could not open");
    return S_OK;  // keep going; the entry is reported as failed
}

HRESULT CUpdateCallback::ReadingFileError(const FString &path, DWORD systemError)
{
    RecordFailure(path, systemError, "could not read");
    return S_OK;
}

HRESULT CUpdateCallback::ScanError(const FString &path, DWORD systemError)
{
    RecordFailure(path, systemError, "could not scan");
    return S_OK;
}

HRESULT CUpdateCallback::ScanProgress(const CDirItemsStat & /* st */, const FString & /* path */,
                                      bool /* isDir */)
{
    return CheckBreak();
}

HRESULT CUpdateCallback::FinishArchive(const CFinishArchiveStat &st)
{
    outcome_.archiveSize = st.OutArcFileSize;
    return S_OK;
}

// --- the parts we have nothing to say about --------------------------------

HRESULT CUpdateCallback::WriteSfx(const wchar_t *, UInt64) { return S_OK; }
HRESULT CUpdateCallback::SetRatioInfo(const UInt64 *, const UInt64 *) { return CheckBreak(); }
HRESULT CUpdateCallback::SetNumItems(const CArcToDoStat &) { return S_OK; }
HRESULT CUpdateCallback::SetOperationResult(Int32) { return S_OK; }
HRESULT CUpdateCallback::ReportExtractResult(Int32, Int32, const wchar_t *) { return S_OK; }
HRESULT CUpdateCallback::ReportUpdateOperation(UInt32, const wchar_t *, bool) { return S_OK; }
HRESULT CUpdateCallback::ShowDeleteFile(const wchar_t *, bool) { return S_OK; }
HRESULT CUpdateCallback::OpenResult(const CCodecs *, const CArchiveLink &, const wchar_t *, HRESULT)
    { return S_OK; }
HRESULT CUpdateCallback::StartScanning() { return S_OK; }
HRESULT CUpdateCallback::FinishScanning(const CDirItemsStat &) { return S_OK; }
HRESULT CUpdateCallback::StartOpenArchive(const wchar_t *) { return S_OK; }
HRESULT CUpdateCallback::StartArchive(const wchar_t *, bool) { return S_OK; }
HRESULT CUpdateCallback::DeletingAfterArchiving(const FString &, bool) { return S_OK; }
HRESULT CUpdateCallback::FinishDeletingAfterArchiving() { return S_OK; }
HRESULT CUpdateCallback::MoveArc_Start(const wchar_t *, const wchar_t *, UInt64, Int32)
    { return S_OK; }
HRESULT CUpdateCallback::MoveArc_Progress(UInt64, UInt64) { return CheckBreak(); }
HRESULT CUpdateCallback::MoveArc_Finish() { return S_OK; }

/// Adds one `-m` style property.
void AddProperty(CObjectVector<CProperty> &properties, const char *name, const UString &value)
{
    CProperty property;
    property.Name = name;
    property.Value = value;
    properties.Add(property);
}

UString NumberToUString(std::uint64_t value)
{
    char buffer[32];
    ConvertUInt64ToString(value, buffer);
    return GetUnicodeString(buffer, CP_UTF8);
}

}  // namespace

Result Create(const std::vector<std::string> &inputPaths,
              const CreateOptions &options,
              const ProgressHandler &progress,
              CreateOutcome &outcome)
{
    Result result;

    CCodecs *codecs = SharedCodecs();
    if (!codecs) {
        result.status = Status::failed;
        result.message = "the engine failed to start";
        return result;
    }
    if (inputPaths.empty()) {
        result.status = Status::failed;
        result.message = "nothing to add";
        return result;
    }

    const UString archivePath = GetUnicodeString(options.archivePath.c_str(), CP_UTF8);

    // Refuse to walk into an existing archive by accident: `Create` means
    // create. Changing an existing one is DeleteEntries, RenameEntries and
    // AddFiles, below.
    if (NWindows::NFile::NFind::DoesFileOrDirExist(us2fs(archivePath))) {
        result.status = Status::failed;
        result.message = "a file already exists at that path";
        return result;
    }

    CObjectVector<COpenType> types;
    if (!options.formatName.empty()) {
        const UString name = GetUnicodeString(options.formatName.c_str(), CP_UTF8);
        if (!ParseOpenTypes(*codecs, name, types)) {
            result.status = Status::unsupported;
            result.message = "unknown archive format: " + options.formatName;
            return result;
        }
    }

    NWildcard::CCensor censor;
    for (const std::string &input : inputPaths) {
        censor.AddPreItem_NoWildcard(GetUnicodeString(input.c_str(), CP_UTF8));
    }

    CUpdateOptions updateOptions;
    updateOptions.SetActionCommand_Add();
    updateOptions.PathMode = NWildcard::k_RelatPath;
    // Store symlinks as links rather than following them, matching what the
    // extraction side already restores.
    updateOptions.SymLinks.Val = true;
    updateOptions.SymLinks.Def = true;
    updateOptions.HardLinks.Val = true;
    updateOptions.HardLinks.Def = true;

    if (!types.IsEmpty()) {
        updateOptions.MethodMode.Type = types[0];
        updateOptions.MethodMode.Type_Defined = true;
    }

    CObjectVector<CProperty> &properties = updateOptions.MethodMode.Properties;
    AddProperty(properties, "x", NumberToUString(static_cast<std::uint64_t>(options.level)));
    if (options.encryptHeader && !options.password.empty()) {
        // 7z spells it `he`; zip has no equivalent and ignores it, so only
        // offer it where it means something.
        AddProperty(properties, "he", UString("on"));
    }
    for (const auto &property : options.methodProperties) {
        AddProperty(properties, property.first.c_str(),
                    GetUnicodeString(property.second.c_str(), CP_UTF8));
    }

    if (options.volumeSize > 0) {
        updateOptions.VolumesSizes.Add(options.volumeSize);
    }

    CUpdateCallback callback (progress, options.password, outcome);
    CUpdateErrorInfo errorInfo;

    const HRESULT hr = UpdateArchive(codecs, types, archivePath, censor, updateOptions,
                                     errorInfo, nullptr /* no open callback: nothing to reopen */,
                                     &callback, true /* needSetPath */);

    if (hr != S_OK) {
        if (callback.Cancelled) {
            result.status = Status::cancelled;
            return result;
        }
        result = ResultFromHRESULT(hr, false, false, false);
        if (!errorInfo.Message.IsEmpty()) {
            result.message = errorInfo.Message.Ptr();
        }
        return result;
    }
    if (callback.Cancelled) {
        result.status = Status::cancelled;
        return result;
    }

    if (!outcome.failures.empty()) {
        result.status = outcome.failures.front().status;
        result.message = outcome.failures.front().message;
    }
    return result;
}

// ---------------------------------------------------------------------------
// Rewriting
// ---------------------------------------------------------------------------

/// The one door into an open Archive's engine objects.
struct Rewriter {
    static const CArchiveLink &Link(const Archive &archive) { return archive.impl_->link; }
    static const CArc &Arc(const Archive &archive) { return *archive.impl_->link.GetArc(); }
};

namespace {

/// UpdateProduce reports what it drops; we have nobody to tell.
struct CSilentProduceCallback Z7_final: public IUpdateProduceCallback {
    HRESULT ShowDeleteFile(unsigned) Z7_override { return S_OK; }
};

/// The part every rewrite shares, and the order 7-Zip's own file manager does
/// it in (UI/Agent/AgentOut.cpp): an IOutArchive from the handler that opened
/// the file, an update callback that knows which items are old, new or
/// renamed, and UpdateItems into a fresh file.
Result RunUpdate(const Archive &archive,
                 const CRecordVector<CUpdatePair2> &pairs,
                 const CObjectVector<CArcItem> *arcItems,
                 const CDirItems *dirItems,
                 const UStringVector *newNames,
                 const ModifyOptions &options,
                 const ProgressHandler &progress,
                 CreateOutcome &outcome)
{
    Result result;
    const std::string why = WhyNotModifiable(archive);
    if (!why.empty()) {
        result.status = Status::unsupported;
        result.message = why;
        return result;
    }

    const CArc &arc = Rewriter::Arc(archive);
    CMyComPtr<IOutArchive> outArchive;
    if (arc.Archive->QueryInterface(IID_IOutArchive, (void **)&outArchive) != S_OK || !outArchive) {
        result.status = Status::unsupported;
        result.message = "this format cannot be written";
        return result;
    }

    // No properties: the handler keeps what it read. That is the point for
    // 7z, which otherwise would quietly drop an encrypted entry list; it
    // keeps one encrypted whenever a password is in play.
    {
        CMyComPtr<ISetProperties> setProperties;
        outArchive.QueryInterface(IID_ISetProperties, &setProperties);
        if (setProperties) {
            const HRESULT hr = setProperties->SetProperties(nullptr, nullptr, 0);
            if (hr != S_OK) {
                return ResultFromHRESULT(hr, false, false, false);
            }
        }
    }

    const FString outputPath = us2fs(GetUnicodeString(options.outputPath.c_str(), CP_UTF8));
    CMyComPtr2_Create<IOutStream, COutFileStream> outStream;
    if (!outStream->Create_NEW(outputPath)) {
        result.status = Status::unreadable;
        result.message = "could not create the new archive";
        return result;
    }

    CUpdateCallback ui (progress, options.password, outcome);
    CMyComPtr2_Create<IArchiveUpdateCallback, CArchiveUpdateCallback> callback;
    callback->Callback = &ui;
    callback->UpdatePairs = &pairs;
    callback->ArcItems = arcItems;
    callback->DirItems = dirItems;
    callback->NewNames = newNames;
    callback->Arc = &arc;
    callback->Archive = arc.Archive;
    callback->ArcFileName = ExtractFileNameFromPath(arc.Path);
    // Store links as links, matching Create and what extraction restores.
    callback->StoreSymLinks = true;
    callback->StoreHardLinks = true;

    HRESULT hr = outArchive->UpdateItems(outStream, pairs.Size(), callback);
    const HRESULT closed = outStream->Close();
    if (hr == S_OK) {
        hr = closed;
    }

    if (hr != S_OK || ui.Cancelled) {
        NWindows::NFile::NDir::DeleteFileAlways(outputPath);
        if (ui.Cancelled) {
            result.status = Status::cancelled;
        } else {
            result = ResultFromHRESULT(hr, ui.PasswordWasAsked, !options.password.empty(),
                                       ui.PasswordUnavailable);
        }
        return result;
    }

    NWindows::NFile::NFind::CFileInfo written;
    if (written.Find(outputPath)) {
        outcome.archiveSize = written.Size;
    }
    if (!outcome.failures.empty()) {
        result.status = outcome.failures.front().status;
        result.message = outcome.failures.front().message;
    }
    return result;
}

}  // namespace

std::string WhyNotModifiable(const Archive &archive)
{
    const CArchiveLink &link = Rewriter::Link(archive);
    if (link.Arcs.Size() != 1) {
        return "this archive was opened through another one";
    }
    if (!link.VolumePaths.IsEmpty()) {
        return "archives split into volumes cannot be changed";
    }
    const CArc &arc = Rewriter::Arc(archive);
    if (arc.IsReadOnly) {
        return "the engine opened this archive read-only";
    }
    CMyComPtr<IOutArchive> outArchive;
    if (arc.Archive->QueryInterface(IID_IOutArchive, (void **)&outArchive) != S_OK || !outArchive) {
        return "this format cannot be written";
    }
    return {};
}

Result DeleteEntries(const Archive &archive,
                     const std::vector<std::uint32_t> &indices,
                     const ModifyOptions &options,
                     const ProgressHandler &progress,
                     CreateOutcome &outcome)
{
    std::vector<bool> doomed (archive.entries().size(), false);
    for (const std::uint32_t index : indices) {
        if (index < doomed.size()) {
            doomed[index] = true;
        }
    }

    CRecordVector<CUpdatePair2> pairs;
    for (std::uint32_t i = 0; i < doomed.size(); i++) {
        if (doomed[i]) {
            continue;
        }
        CUpdatePair2 pair;
        pair.SetAs_NoChangeArcItem(i);
        pairs.Add(pair);
    }
    return RunUpdate(archive, pairs, nullptr, nullptr, nullptr, options, progress, outcome);
}

Result RenameEntries(const Archive &archive,
                     const std::vector<std::pair<std::uint32_t, std::string>> &renames,
                     const ModifyOptions &options,
                     const ProgressHandler &progress,
                     CreateOutcome &outcome)
{
    std::map<std::uint32_t, unsigned> nameIndex;
    UStringVector newNames;
    for (const auto &rename : renames) {
        nameIndex[rename.first] = newNames.Add(GetUnicodeString(rename.second.c_str(), CP_UTF8));
    }

    const CArc &arc = Rewriter::Arc(archive);
    CRecordVector<CUpdatePair2> pairs;
    for (std::uint32_t i = 0; i < archive.entries().size(); i++) {
        CUpdatePair2 pair;
        pair.SetAs_NoChangeArcItem(i);
        const auto found = nameIndex.find(i);
        if (found != nameIndex.end()) {
            // New properties, old data: the name changes and nothing is
            // recompressed. UseArcProps stays on, so every other property is
            // read from the archive as it was.
            pair.NewProps = true;
            arc.IsItem_Anti(i, pair.IsAnti);
            pair.NewNameIndex = static_cast<int>(found->second);
            pair.IsMainRenameItem = true;
        }
        pairs.Add(pair);
    }
    return RunUpdate(archive, pairs, nullptr, nullptr, &newNames, options, progress, outcome);
}

Result AddFiles(const Archive &archive,
                const std::vector<std::string> &inputPaths,
                const std::string &folderInArchive,
                AddPolicy policy,
                const ModifyOptions &options,
                const ProgressHandler &progress,
                CreateOutcome &outcome)
{
    Result result;
    if (inputPaths.empty()) {
        result.status = Status::failed;
        result.message = "nothing to add";
        return result;
    }
    const std::string why = WhyNotModifiable(archive);
    if (!why.empty()) {
        result.status = Status::unsupported;
        result.message = why;
        return result;
    }

    const CArc &arc = Rewriter::Arc(archive);
    CUpdateCallback scanUI (progress, options.password, outcome);

    // The files on disk. A physical prefix of "/" and absolute paths below it
    // means every input keeps its own name and drops its parents -- the
    // prefix directories of the paths are not stored, EnumerateItems2 says.
    CDirItems dirItems;
    dirItems.Callback = &scanUI;
    dirItems.SymLinks = true;
    FStringVector names;
    for (const std::string &input : inputPaths) {
        FString path = us2fs(GetUnicodeString(input.c_str(), CP_UTF8));
        while (path.Len() > 1 && IS_PATH_SEPAR(path.Back())) {
            path.DeleteBack();
        }
        if (!path.IsEmpty() && IS_PATH_SEPAR(path[0])) {
            path.Delete(0);
        }
        names.Add(path);
    }
    UString logPrefix = GetUnicodeString(folderInArchive.c_str(), CP_UTF8);
    if (!logPrefix.IsEmpty() && !IS_PATH_SEPAR(logPrefix.Back())) {
        logPrefix.Add_PathSepar();
    }
    HRESULT hr = dirItems.EnumerateItems2(FString(FTEXT("/")), logPrefix, names, nullptr);
    if (hr != S_OK) {
        return ResultFromHRESULT(hr, false, false, false);
    }
    if (!outcome.failures.empty()) {
        // A file that could not even be found is not something to half-add.
        result.status = outcome.failures.front().status;
        result.message = outcome.failures.front().message;
        return result;
    }

    // The files already there, named the way CDirItems names its logical
    // paths, so the two lists can be paired up by name.
    CObjectVector<CArcItem> arcItems;
    for (std::uint32_t i = 0; i < archive.entries().size(); i++) {
        CArcItem item;
        item.IndexInServer = i;
        item.Censored = true;   // every entry is in scope for pairing
        if (arc.GetItem_Path2(i, item.Name) != S_OK
            || Archive_IsItem_Dir(arc.Archive, i, item.IsDir) != S_OK
            || Archive_IsItem_AltStream(arc.Archive, i, item.IsAltStream) != S_OK
            || arc.GetItem_MTime(i, item.MTime) != S_OK
            || arc.GetItem_Size(i, item.Size, item.Size_Defined) != S_OK) {
            result.status = Status::damaged;
            result.message = "the archive would not describe its entries";
            return result;
        }
        arcItems.Add(item);
    }

    CMyComPtr<IOutArchive> outArchive;
    arc.Archive->QueryInterface(IID_IOutArchive, (void **)&outArchive);
    UInt32 timeType = NFileTimeType::kWindows;
    if (outArchive) {
        outArchive->GetFileTimeType(&timeType);
    }

    CRecordVector<CUpdatePair2> pairs;
    try {
        CRecordVector<CUpdatePair> matched;
        GetUpdatePairInfoList(dirItems, arcItems, (NFileTimeType::EEnum)timeType, matched);
        CSilentProduceCallback produce;
        UpdateProduce(matched,
                      policy == AddPolicy::onlyIfNewer ? NUpdateArchive::k_ActionSet_Update
                                                       : NUpdateArchive::k_ActionSet_Add,
                      pairs, &produce);
    } catch (const UString &message) {
        // Pairing throws for the one thing it cannot resolve: two entries of
        // the same name, on either side, that an incoming file would match.
        result.status = Status::unsupported;
        result.message = UnicodeStringToMultiByte(message, CP_UTF8).Ptr();
        return result;
    }

    return RunUpdate(archive, pairs, &arcItems, &dirItems, nullptr, options, progress, outcome);
}

}  // namespace szk
