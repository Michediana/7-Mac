//
//  SZKBridging.mm
//  SevenZipKit
//

#import "SZKBridging.h"

NSErrorDomain const SZKErrorDomain = @"SevenZipKitErrorDomain";

#pragma mark - Text and dates

NSString *SZKStringFromText(const szk::Text &text)
{
    if (text.empty()) {
        return @"";
    }
    NSString *string = [[NSString alloc] initWithBytes:text.data()
                                                length:text.size()
                                              encoding:NSUTF32LittleEndianStringEncoding];
    return string ?: @"";
}

szk::Text SZKTextFromString(NSString *string)
{
    NSData *data = [string dataUsingEncoding:NSUTF32LittleEndianStringEncoding];
    const auto *first = static_cast<const uint8_t *>(data.bytes);
    return szk::Text(first, first + data.length);
}

NSDate *SZKDateFromNanoseconds(bool has, int64_t nanoseconds)
{
    if (!has) {
        return nil;
    }
    return [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)nanoseconds / 1e9];
}

#pragma mark - Errors

static SZKError SZKCodeFromStatus(szk::Status status)
{
    switch (status) {
        case szk::Status::ok:               return SZKErrorFailed;  // not an error; caller checks first
        case szk::Status::cancelled:        return SZKErrorCancelled;
        case szk::Status::passwordRequired: return SZKErrorPasswordRequired;
        case szk::Status::passwordWrong:    return SZKErrorPasswordWrong;
        case szk::Status::notAnArchive:     return SZKErrorNotAnArchive;
        case szk::Status::unreadable:       return SZKErrorUnreadable;
        case szk::Status::damaged:          return SZKErrorDamaged;
        case szk::Status::unsupported:      return SZKErrorUnsupported;
        case szk::Status::failed:           return SZKErrorFailed;
    }
    return SZKErrorFailed;
}

static NSString *SZKDescriptionForStatus(szk::Status status)
{
    switch (status) {
        case szk::Status::ok:               return @"No error.";
        case szk::Status::cancelled:        return @"The operation was cancelled.";
        case szk::Status::passwordRequired: return @"This archive is encrypted and needs a password.";
        case szk::Status::passwordWrong:    return @"The password is not correct.";
        case szk::Status::notAnArchive:     return @"This file is not an archive in any format the engine reads.";
        case szk::Status::unreadable:       return @"The file could not be read, or the destination could not be written.";
        case szk::Status::damaged:          return @"The archive is damaged.";
        case szk::Status::unsupported:      return @"The engine cannot do this with this format.";
        case szk::Status::failed:           return @"The operation failed.";
    }
    return @"The operation failed.";
}

static NSError *SZKMakeError(szk::Status status, const std::string &message, NSString *_Nullable path)
{
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[NSLocalizedDescriptionKey] = SZKDescriptionForStatus(status);
    if (!message.empty()) {
        info[NSDebugDescriptionErrorKey] = @(message.c_str());
    }
    if (path.length > 0) {
        info[NSFilePathErrorKey] = path;
    }
    return [NSError errorWithDomain:SZKErrorDomain code:SZKCodeFromStatus(status) userInfo:info];
}

NSError *SZKErrorFromResult(const szk::Result &result)
{
    return SZKMakeError(result.status, result.message, nil);
}

NSError *SZKErrorFromEntryFailure(const szk::EntryFailure &failure)
{
    NSString *path = SZKStringFromText(failure.path);
    return SZKMakeError(failure.status, failure.message, path.length > 0 ? path : nil);
}

#pragma mark - Handler bridging

szk::PasswordProvider SZKMakePasswordProvider(SZKPasswordProvider provider)
{
    if (!provider) {
        return nullptr;
    }
    return [provider](std::string &password) {
        NSString *supplied = provider();
        if (!supplied) {
            return false;   // the caller declined: cancel
        }
        password = supplied.UTF8String;
        return true;
    };
}

szk::ProgressHandler SZKMakeProgressHandler(SZKProgressHandler handler)
{
    if (!handler) {
        return nullptr;
    }
    return [handler](const szk::Progress &state) {
        @autoreleasepool {
            // The engine reports progress hundreds of times for a large
            // archive; without a pool the SZKProgress objects pile up until
            // the operation ends.
            return handler([[SZKProgress alloc] initWithState:state]) != NO;
        }
    };
}

szk::OverwriteHandler SZKMakeOverwriteHandler(SZKOverwriteHandler handler)
{
    if (!handler) {
        return nullptr;
    }
    return [handler](const szk::OverwriteRequest &request) {
        @autoreleasepool {
            SZKOverwriteRequest *boxed = [[SZKOverwriteRequest alloc] initWithRequest:request];
            switch (handler(boxed)) {
                case SZKOverwriteDecisionOverwrite:    return szk::OverwriteDecision::overwrite;
                case SZKOverwriteDecisionOverwriteAll: return szk::OverwriteDecision::overwriteAll;
                case SZKOverwriteDecisionSkip:         return szk::OverwriteDecision::skip;
                case SZKOverwriteDecisionSkipAll:      return szk::OverwriteDecision::skipAll;
                case SZKOverwriteDecisionAutoRename:   return szk::OverwriteDecision::autoRename;
                case SZKOverwriteDecisionCancel:       return szk::OverwriteDecision::cancel;
            }
            return szk::OverwriteDecision::cancel;
        }
    };
}

#pragma mark - Value types

@implementation SZKProgress

- (instancetype)initWithState:(const szk::Progress &)state
{
    self = [super init];
    if (self) {
        _totalBytes = state.totalBytes;
        _completedBytes = state.completedBytes;
        _currentPath = SZKStringFromText(state.currentPath);
        _currentIsDirectory = state.currentIsDirectory;
    }
    return self;
}

- (NSNumber *)fractionCompleted
{
    if (_totalBytes == 0) {
        return nil;
    }
    return @(MIN(1.0, (double)_completedBytes / (double)_totalBytes));
}

@end

@implementation SZKOverwriteRequest

- (instancetype)initWithRequest:(const szk::OverwriteRequest &)request
{
    self = [super init];
    if (self) {
        _existingPath = SZKStringFromText(request.existingPath);
        _existingSize = request.hasExistingSize ? @(request.existingSize) : nil;
        _existingModificationDate =
            SZKDateFromNanoseconds(request.hasExistingModified, request.existingModified);
        _incomingPath = SZKStringFromText(request.incomingPath);
        _incomingSize = request.hasIncomingSize ? @(request.incomingSize) : nil;
        _incomingModificationDate =
            SZKDateFromNanoseconds(request.hasIncomingModified, request.incomingModified);
    }
    return self;
}

@end

@implementation SZKOutcome

static NSArray<NSError *> *SZKErrorsFromFailures(const std::vector<szk::EntryFailure> &failures)
{
    NSMutableArray<NSError *> *errors = [NSMutableArray arrayWithCapacity:failures.size()];
    for (const szk::EntryFailure &failure : failures) {
        [errors addObject:SZKErrorFromEntryFailure(failure)];
    }
    return errors;
}

- (instancetype)initWithExtractOutcome:(const szk::ExtractOutcome &)outcome
{
    self = [super init];
    if (self) {
        _fileCount = outcome.files;
        _folderCount = outcome.folders;
        _byteCount = outcome.bytes;
        _processedByteCount = outcome.bytesProcessed;
        _entryErrors = SZKErrorsFromFailures(outcome.failures);
    }
    return self;
}

- (instancetype)initWithFileCount:(uint64_t)fileCount
                      folderCount:(uint64_t)folderCount
                      archiveSize:(uint64_t)archiveSize
                         failures:(const std::vector<szk::EntryFailure> &)failures
{
    self = [super init];
    if (self) {
        _fileCount = fileCount;
        _folderCount = folderCount;
        _archiveSize = archiveSize;
        _entryErrors = SZKErrorsFromFailures(failures);
    }
    return self;
}

@end
