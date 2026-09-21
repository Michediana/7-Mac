//
//  SZKEngineCore.cpp
//  SevenZipKit
//
//  The only translation unit that sees the 7-Zip COM headers. See the header
//  for why that boundary exists.
//

#include "SZKEngineCore.hpp"

#include <mutex>

// No MyInitGuid.h here. That header is what *defines* the IID/CLSID constants,
// and the engine archive already contains those definitions -- one translation
// unit may define them, and that is the engine's own SevenZipKitInit.cpp.
#include "Common/MyWindows.h"

#include "7zVersion.h"
#include "7zip/UI/Common/LoadCodecs.h"

#include "SZKEngineCoreInternal.hpp"

namespace szk {

Text TextFromUString(const UString &s)
{
    const auto *first = reinterpret_cast<const std::uint8_t *>(s.Ptr());
    return Text(first, first + s.Len() * sizeof(wchar_t));
}

namespace {

Bytes BytesFromBuffer(const CByteBuffer &buffer)
{
    const std::uint8_t *first = buffer;
    return Bytes(first, first + buffer.Size());
}

std::vector<FormatInfo> BuildFormats();

}  // namespace

/// The engine's codec and handler registry.
///
/// Built once. Without Z7_EXTERNAL_CODECS this reads the statically registered
/// handler table and touches no filesystem, which is exactly what we want
/// inside a sandbox -- see Scripts/engine/README.md.
CCodecs *SharedCodecs()
{
    static CCodecs *codecs = nullptr;
    static std::once_flag once;
    std::call_once(once, [] {
        CMyComPtr<IUnknown> owner;  // keeps the refcounted object alive for the process
        auto *created = new CCodecs;
        owner = created;
        if (created->Load() != S_OK) {
            return;
        }
        owner.Detach();
        codecs = created;
    });
    return codecs;
}

namespace {

std::vector<FormatInfo> BuildFormats()
{
    std::vector<FormatInfo> formats;
    const CCodecs *codecs = SharedCodecs();
    if (!codecs) {
        return formats;
    }

    formats.reserve(codecs->Formats.Size());
    FOR_VECTOR (i, codecs->Formats) {
        const CArcInfoEx &arc = codecs->Formats[i];

        FormatInfo info;
        info.index = i;
        info.name = TextFromUString(arc.Name);
        info.writable = arc.UpdateEnabled;
        info.keepsName = arc.Flags_KeepName();
        info.supportsAlternateStreams = arc.Flags_AltStreams();
        info.supportsSymbolicLinks = arc.Flags_SymLinks();
        info.flags = arc.Flags;
        info.signatureOffset = arc.SignatureOffset;

        FOR_VECTOR (e, arc.Exts) {
            info.extensions.push_back(TextFromUString(arc.Exts[e].Ext));
            info.addedExtensions.push_back(TextFromUString(arc.Exts[e].AddExt));
        }

        FOR_VECTOR (s, arc.Signatures) {
            info.signatures.push_back(BytesFromBuffer(arc.Signatures[s]));
        }

        formats.push_back(std::move(info));
    }
    return formats;
}

}  // namespace

const std::vector<FormatInfo> &AllFormats()
{
    static const std::vector<FormatInfo> formats = BuildFormats();
    return formats;
}

std::string UpstreamVersion() { return MY_VERSION; }

std::string UpstreamDate() { return MY_DATE; }

}  // namespace szk
