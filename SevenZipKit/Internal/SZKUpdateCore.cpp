//
//  SZKUpdateCore.cpp
//  SevenZipKit
//
//  Creating archives, and the COM-ish callback that creation needs.
//

#include "SZKUpdateCore.hpp"

#include <cstdio>

#include "Common/MyWindows.h"

#include "Common/IntToString.h"
#include "Common/StringConvert.h"
#include "Windows/FileFind.h"
#include "7zip/UI/Common/LoadCodecs.h"
#include "7zip/UI/Common/OpenArchive.h"
#include "7zip/UI/Common/Update.h"

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
    if (password_.empty()) {
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
    // create. Updating in place is M4's job and will be its own entry point.
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

}  // namespace szk
