//
//  SZKArchive.mm
//  SevenZipKit
//

#import "SZKArchive.h"

#import "Internal/SZKArchiveEntry+Private.h"
#import "Internal/SZKBridging.h"
#import "Internal/SZKUpdateCore.hpp"

#import "SZKArchiveEntry.h"

namespace {

/// Every path we hand the engine is a plain filesystem path. `NSURL.path`
/// rather than `fileSystemRepresentation` so that the round trip through
/// std::string stays UTF-8, which is what the engine expects.
std::string PathFromURL(NSURL *url)
{
    return url.path.UTF8String ?: "";
}

std::vector<std::uint32_t> IndicesFromIndexSet(NSIndexSet *_Nullable indexes)
{
    std::vector<std::uint32_t> indices;
    if (!indexes) {
        return indices;   // empty means "everything"
    }
    indices.reserve(indexes.count);
    // Not enumerateIndexesUsingBlock: a block captures a C++ object by const
    // copy, so nothing written inside it would survive.
    for (NSUInteger index = indexes.firstIndex; index != NSNotFound;
         index = [indexes indexGreaterThanIndex:index]) {
        indices.push_back(static_cast<std::uint32_t>(index));
    }
    return indices;
}

}  // namespace

@interface SZKArchive ()
- (instancetype)initWithArchive:(std::unique_ptr<szk::Archive>)archive url:(NSURL *)url;
@end

@implementation SZKArchive {
    std::unique_ptr<szk::Archive> _archive;
}

+ (instancetype)archiveAtURL:(NSURL *)url
            passwordProvider:(SZKPasswordProvider)passwordProvider
                       error:(NSError **)error
{
    szk::Result result;
    szk::PasswordProvider password = SZKMakePasswordProvider(passwordProvider);
    std::unique_ptr<szk::Archive> opened =
        szk::Archive::Open(PathFromURL(url), password, nullptr, result);

    if (!opened) {
        if (error) {
            *error = SZKErrorFromResult(result);
        }
        return nil;
    }
    return [[self alloc] initWithArchive:std::move(opened) url:url];
}

- (instancetype)initWithArchive:(std::unique_ptr<szk::Archive>)archive url:(NSURL *)url
{
    self = [super init];
    if (self) {
        _archive = std::move(archive);

        const szk::ArchiveInfo &info = _archive->info();
        _formatName = SZKStringFromText(info.formatName);
        _formatIndex = info.formatIndex;
        _physicalSize = info.hasPhysicalSize ? @(info.physicalSize) : nil;
        _hasEncryptedHeader = info.headerEncrypted;
        _volumeCount = info.volumeCount;

        NSMutableArray<NSURL *> *volumes =
            [NSMutableArray arrayWithCapacity:info.volumePaths.size()];
        for (const szk::Text &path : info.volumePaths) {
            [volumes addObject:[NSURL fileURLWithPath:SZKStringFromText(path)]];
        }
        _additionalVolumeURLs = volumes;

        const std::vector<szk::EntryInfo> &entries = _archive->entries();
        NSMutableArray<SZKArchiveEntry *> *boxed =
            [NSMutableArray arrayWithCapacity:entries.size()];
        for (const szk::EntryInfo &entry : entries) {
            [boxed addObject:[[SZKArchiveEntry alloc] initWithEntry:entry]];
        }
        _entries = boxed;
        _url = [url copy];
    }
    return self;
}

- (SZKArchive *)openEntryAtIndex:(NSUInteger)index
                passwordProvider:(SZKPasswordProvider)passwordProvider
                           error:(NSError **)error
{
    if (index >= _entries.count) {
        if (error) {
            szk::Result result;
            result.status = szk::Status::failed;
            result.message = "no such entry";
            *error = SZKErrorFromResult(result);
        }
        return nil;
    }

    szk::Result result;
    szk::PasswordProvider password = SZKMakePasswordProvider(passwordProvider);
    std::unique_ptr<szk::Archive> opened =
        _archive->OpenEntry(static_cast<std::uint32_t>(index), password, result);
    if (!opened) {
        if (error) {
            *error = SZKErrorFromResult(result);
        }
        return nil;
    }

    SZKArchive *nested = [[SZKArchive alloc] initWithArchive:std::move(opened) url:_url];
    // The nested handler reads through our stream: it must not outlive us.
    nested->_parentArchive = self;
    nested->_pathInParent = [_entries[index].path copy];
    return nested;
}

#pragma mark - Extracting

- (BOOL)extractIndexes:(NSIndexSet *)indexes
               options:(SZKExtractOptions *)options
              progress:(SZKProgressHandler)progress
      passwordProvider:(SZKPasswordProvider)passwordProvider
      overwriteHandler:(SZKOverwriteHandler)overwriteHandler
               outcome:(SZKOutcome *__autoreleasing *)outcome
                 error:(NSError **)error
{
    szk::ExtractOptions coreOptions;
    coreOptions.destinationDirectory = PathFromURL(options.destinationDirectory);
    coreOptions.paths = (options.paths == SZKPathPolicyFlatten) ? szk::PathPolicy::flatten
                                                                : szk::PathPolicy::fullPaths;
    coreOptions.relativeToCommonParent = options.relativeToCommonParent;
    switch (options.overwrite) {
        case SZKOverwritePolicyAsk:            coreOptions.overwrite = szk::OverwritePolicy::ask; break;
        case SZKOverwritePolicyOverwrite:      coreOptions.overwrite = szk::OverwritePolicy::overwrite; break;
        case SZKOverwritePolicySkip:           coreOptions.overwrite = szk::OverwritePolicy::skip; break;
        case SZKOverwritePolicyAutoRename:     coreOptions.overwrite = szk::OverwritePolicy::autoRename; break;
        case SZKOverwritePolicyRenameExisting: coreOptions.overwrite = szk::OverwritePolicy::renameExisting; break;
    }

    return [self runExtract:IndicesFromIndexSet(indexes)
                    options:coreOptions
                   progress:progress
           passwordProvider:passwordProvider
           overwriteHandler:overwriteHandler
                    outcome:outcome
                      error:error];
}

- (BOOL)testIndexes:(NSIndexSet *)indexes
           progress:(SZKProgressHandler)progress
   passwordProvider:(SZKPasswordProvider)passwordProvider
            outcome:(SZKOutcome *__autoreleasing *)outcome
              error:(NSError **)error
{
    szk::ExtractOptions coreOptions;
    coreOptions.testOnly = true;
    return [self runExtract:IndicesFromIndexSet(indexes)
                    options:coreOptions
                   progress:progress
           passwordProvider:passwordProvider
           overwriteHandler:nil
                    outcome:outcome
                      error:error];
}

- (BOOL)runExtract:(const std::vector<std::uint32_t> &)indices
           options:(const szk::ExtractOptions &)options
          progress:(SZKProgressHandler)progress
  passwordProvider:(SZKPasswordProvider)passwordProvider
  overwriteHandler:(SZKOverwriteHandler)overwriteHandler
           outcome:(SZKOutcome *__autoreleasing *)outcome
             error:(NSError **)error
{
    szk::ExtractOutcome coreOutcome;
    const szk::Result result = _archive->Extract(indices, options,
                                                 SZKMakeProgressHandler(progress),
                                                 SZKMakePasswordProvider(passwordProvider),
                                                 SZKMakeOverwriteHandler(overwriteHandler),
                                                 coreOutcome);

    // The outcome is worth having either way: a run that wrote 900 of 1000
    // files should say so, not just fail.
    if (outcome) {
        *outcome = [[SZKOutcome alloc] initWithExtractOutcome:coreOutcome];
    }
    if (!result.ok()) {
        if (error) {
            *error = SZKErrorFromResult(result);
        }
        return NO;
    }
    return YES;
}

#pragma mark - Creating

+ (BOOL)createArchiveAtURL:(NSURL *)url
                  fromURLs:(NSArray<NSURL *> *)sourceURLs
                   options:(SZKCreateOptions *)options
                  progress:(SZKProgressHandler)progress
                   outcome:(SZKOutcome *__autoreleasing *)outcome
                     error:(NSError **)error
{
    szk::CreateOptions coreOptions;
    coreOptions.archivePath = PathFromURL(url);
    if (options.formatName) {
        coreOptions.formatName = options.formatName.UTF8String;
    }
    coreOptions.level = static_cast<szk::CompressionLevel>(options.level);
    if (options.password) {
        coreOptions.password = options.password.UTF8String;
    }
    coreOptions.encryptHeader = options.encryptsHeader;
    coreOptions.volumeSize = options.volumeSize;
    for (NSString *key in options.methodProperties) {
        coreOptions.methodProperties.emplace_back(key.UTF8String,
                                                  options.methodProperties[key].UTF8String);
    }

    std::vector<std::string> inputs;
    inputs.reserve(sourceURLs.count);
    for (NSURL *source in sourceURLs) {
        inputs.push_back(PathFromURL(source));
    }

    szk::CreateOutcome coreOutcome;
    const szk::Result result = szk::Create(inputs, coreOptions,
                                           SZKMakeProgressHandler(progress), coreOutcome);

    if (outcome) {
        *outcome = [[SZKOutcome alloc] initWithFileCount:coreOutcome.files
                                             folderCount:coreOutcome.folders
                                             archiveSize:coreOutcome.archiveSize
                                                failures:coreOutcome.failures];
    }
    if (!result.ok()) {
        if (error) {
            *error = SZKErrorFromResult(result);
        }
        return NO;
    }
    return YES;
}

@end
