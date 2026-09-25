//
//  SZKHashCore.cpp
//  SevenZipKit
//
//  Checksums through upstream's own HashCalc -- the code behind `7zz h` --
//  so a figure here is the figure 7-Zip prints.
//

#include "SZKHashInternal.hpp"

#include "Common/StringConvert.h"
#include "7zip/Common/CreateCoder.h"
#include "7zip/Common/RegisterCodec.h"

#include "SZKEngineCoreInternal.hpp"
#include "SZKStatus.hpp"

extern unsigned g_NumHashers;
extern const CHasherInfo *g_Hashers[];

namespace szk {

// ---------------------------------------------------------------------------
// Shared with the archive side
// ---------------------------------------------------------------------------

void CCapturingHash::Final(bool isDir, bool isAltStream, const UString &path)
{
    const UInt64 size = Bundle.CurSize;
    Bundle.Final(isDir, isAltStream, path);
    if (isAltStream) {
        return;
    }

    HashedItem item;
    item.path = TextFromUString(path);
    item.isDirectory = isDir;
    item.size = isDir ? 0 : size;
    if (!isDir) {
        // Final() has just put this file's digest in slot 0 and restarted
        // the hasher; the digest stays there until the next file's Final.
        char buffer[k_HashCalc_DigestSize_Max * 2 + 32];
        FOR_VECTOR (i, Bundle.Hashers) {
            Bundle.Hashers[i].WriteToString(k_HashCalc_Index_Current, buffer);
            item.digests.emplace_back(buffer);
        }
    }
    Items.push_back(std::move(item));
}

std::vector<std::string> CCapturingHash::MethodNames() const
{
    std::vector<std::string> names;
    FOR_VECTOR (i, Bundle.Hashers) {
        names.emplace_back(Bundle.Hashers[i].Name.Ptr());
    }
    return names;
}

std::vector<std::string> CCapturingHash::DataSums() const
{
    std::vector<std::string> sums;
    char buffer[k_HashCalc_DigestSize_Max * 2 + 32];
    FOR_VECTOR (i, Bundle.Hashers) {
        Bundle.Hashers[i].WriteToString(k_HashCalc_Index_DataSum, buffer);
        sums.emplace_back(buffer);
    }
    return sums;
}

UStringVector HashMethodNames(const std::vector<std::string> &methods)
{
    UStringVector names;
    for (const std::string &method : methods) {
        names.Add(GetUnicodeString(method.c_str(), CP_UTF8));
    }
    return names;
}

std::vector<HashMethodInfo> HashMethods()
{
    SharedCodecs();   // registration happens with the rest of the engine
    std::vector<HashMethodInfo> methods;
    for (unsigned i = 0; i < g_NumHashers; i++) {
        HashMethodInfo info;
        info.name = g_Hashers[i]->Name;
        info.digestSize = g_Hashers[i]->DigestSize;
        methods.push_back(std::move(info));
    }
    return methods;
}

// ---------------------------------------------------------------------------
// Files on disk
// ---------------------------------------------------------------------------

namespace {

/// HashCalc's questions. Like the update callback, most of it is S_OK; what
/// matters is progress, cancellation and the errors.
class CHashFilesCallback Z7_final: public IHashCallbackUI {
    Z7_IFACE_IMP(IDirItemsCallback)
    Z7_IFACE_IMP(IHashCallbackUI)

public:
    CHashFilesCallback(const ProgressHandler &progress, HashOutcome &outcome)
        : progress_(progress), outcome_(outcome) {}

    bool Cancelled = false;

private:
    /// Reads the digests out of the bundle HashCalc owns. They are only
    /// valid for this one file, at this one moment: the next file's Final
    /// overwrites them.
    static std::vector<std::string> Digests(const CHashBundle &hb, unsigned group)
    {
        std::vector<std::string> digests;
        char buffer[k_HashCalc_DigestSize_Max * 2 + 32];
        FOR_VECTOR (i, hb.Hashers) {
            hb.Hashers[i].WriteToString(group, buffer);
            digests.emplace_back(buffer);
        }
        return digests;
    }

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

    void Fail(const FString &path, DWORD systemError, const char *what)
    {
        EntryFailure failure;
        failure.path = TextFromUString(fs2us(path));
        failure.status = Status::unreadable;
        failure.message = std::string(what) + " (errno=" + std::to_string(systemError) + ")";
        outcome_.failures.push_back(std::move(failure));
    }

    const ProgressHandler &progress_;
    HashOutcome &outcome_;
    Progress state_;
};

HRESULT CHashFilesCallback::ScanProgress(const CDirItemsStat &, const FString &, bool)
    { return Cancelled ? E_ABORT : S_OK; }
HRESULT CHashFilesCallback::ScanError(const FString &path, DWORD systemError)
{
    Fail(path, systemError, "could not scan");
    return S_OK;
}
HRESULT CHashFilesCallback::StartScanning() { return S_OK; }
HRESULT CHashFilesCallback::FinishScanning(const CDirItemsStat &) { return S_OK; }
HRESULT CHashFilesCallback::SetNumFiles(UInt64) { return S_OK; }
HRESULT CHashFilesCallback::SetTotal(UInt64 size)
{
    state_.totalBytes = size;
    return Report();
}
HRESULT CHashFilesCallback::SetCompleted(const UInt64 *completeValue)
{
    if (completeValue) {
        state_.completedBytes = *completeValue;
    }
    return Report();
}
HRESULT CHashFilesCallback::CheckBreak() { return Cancelled ? E_ABORT : S_OK; }
HRESULT CHashFilesCallback::BeforeFirstFile(const CHashBundle &) { return S_OK; }
HRESULT CHashFilesCallback::GetStream(const wchar_t *name, bool isFolder)
{
    state_.currentPath = name ? TextFromUString(UString(name)) : Text();
    state_.currentIsDirectory = isFolder;
    return Report();
}
HRESULT CHashFilesCallback::OpenFileError(const FString &path, DWORD systemError)
{
    Fail(path, systemError, "could not open");
    return S_OK;
}
HRESULT CHashFilesCallback::SetOperationResult(UInt64 fileSize, const CHashBundle &hb, bool showHash)
{
    HashedItem item;
    item.path = state_.currentPath;
    item.isDirectory = state_.currentIsDirectory;
    item.size = item.isDirectory ? 0 : fileSize;
    if (showHash) {
        item.digests = Digests(hb, k_HashCalc_Index_Current);
    }
    outcome_.items.push_back(std::move(item));
    if (!state_.currentIsDirectory) {
        outcome_.files++;
        outcome_.bytes += fileSize;
    }
    return CheckBreak();
}

HRESULT CHashFilesCallback::AfterLastFile(CHashBundle &hb)
{
    FOR_VECTOR (i, hb.Hashers) {
        outcome_.methods.emplace_back(hb.Hashers[i].Name.Ptr());
    }
    outcome_.dataSums = Digests(hb, k_HashCalc_Index_DataSum);
    return S_OK;
}

}  // namespace

Result HashFiles(const std::vector<std::string> &inputPaths,
                 const std::vector<std::string> &methods,
                 const ProgressHandler &progress,
                 HashOutcome &outcome)
{
    Result result;
    if (inputPaths.empty()) {
        result.status = Status::failed;
        result.message = "nothing to hash";
        return result;
    }

    NWildcard::CCensor censor;
    for (const std::string &input : inputPaths) {
        censor.AddPreItem_NoWildcard(GetUnicodeString(input.c_str(), CP_UTF8));
    }
    // UpdateArchive does this itself; HashCalc leaves it to its caller, and
    // without it the censor matches nothing and the report is silently empty.
    censor.AddPathsToCensor(NWildcard::k_RelatPath);

    CHashOptions options;
    options.Methods = HashMethodNames(methods);
    options.PathMode = NWildcard::k_RelatPath;
    // A link is hashed as a link -- its target path -- not followed: the
    // same thing Create stores.
    options.SymLinks.Val = true;
    options.SymLinks.Def = true;

    CHashFilesCallback callback (progress, outcome);
    AString errorInfo;
    const HRESULT hr = HashCalc(censor, options, errorInfo, &callback);
    if (hr != S_OK) {
        if (callback.Cancelled) {
            result.status = Status::cancelled;
            return result;
        }
        result = ResultFromHRESULT(hr, false, false, false);
        if (hr == E_NOTIMPL) {
            result.message = "unknown hash method";
        } else if (!errorInfo.IsEmpty()) {
            result.message = errorInfo.Ptr();
        }
        return result;
    }
    if (!outcome.failures.empty()) {
        result.status = outcome.failures.front().status;
        result.message = outcome.failures.front().message;
    }
    return result;
}

Result HashEntries(Archive &archive,
                   const std::vector<std::uint32_t> &indices,
                   const std::vector<std::string> &methods,
                   const ProgressHandler &progress,
                   const PasswordProvider &password,
                   HashOutcome &outcome)
{
    ExtractOptions options;
    options.testOnly = true;
    options.hashMethods = methods;
    ExtractOutcome extracted;
    const Result result = archive.Extract(indices, options, progress, password, nullptr, extracted);
    outcome.methods = extracted.hashMethods;
    outcome.items = std::move(extracted.hashes);
    outcome.dataSums = extracted.hashSums;
    outcome.files = extracted.files;
    outcome.bytes = extracted.bytes;
    outcome.failures = std::move(extracted.failures);
    return result;
}

}  // namespace szk
