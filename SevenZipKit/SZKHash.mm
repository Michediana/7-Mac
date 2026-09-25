//
//  SZKHash.mm
//  SevenZipKit
//

#import "SZKHash.h"

#import "Internal/SZKBridging.h"
#import "Internal/SZKHashCore.hpp"
#import "Internal/SZKHash+Private.h"

@implementation SZKHashedItem

- (instancetype)initWithItem:(const szk::HashedItem &)item
{
    self = [super init];
    if (self) {
        _path = SZKStringFromText(item.path);
        _isDirectory = item.isDirectory;
        _size = item.size;
        NSMutableArray<NSString *> *digests = [NSMutableArray arrayWithCapacity:item.digests.size()];
        for (const std::string &digest : item.digests) {
            [digests addObject:@(digest.c_str())];
        }
        _digests = digests;
    }
    return self;
}

@end

static NSArray<NSString *> *SZKStrings(const std::vector<std::string> &strings)
{
    NSMutableArray<NSString *> *result = [NSMutableArray arrayWithCapacity:strings.size()];
    for (const std::string &string : strings) {
        [result addObject:@(string.c_str())];
    }
    return result;
}

@implementation SZKHashReport

- (instancetype)initWithOutcome:(const szk::HashOutcome &)outcome
{
    self = [super init];
    if (self) {
        _methods = SZKStrings(outcome.methods);
        _dataSums = SZKStrings(outcome.dataSums);
        _fileCount = outcome.files;
        _byteCount = outcome.bytes;
        NSMutableArray<SZKHashedItem *> *items = [NSMutableArray arrayWithCapacity:outcome.items.size()];
        for (const szk::HashedItem &item : outcome.items) {
            [items addObject:[[SZKHashedItem alloc] initWithItem:item]];
        }
        _items = items;
        NSMutableArray<NSError *> *failures = [NSMutableArray arrayWithCapacity:outcome.failures.size()];
        for (const szk::EntryFailure &failure : outcome.failures) {
            [failures addObject:SZKErrorFromEntryFailure(failure)];
        }
        _failures = failures;
    }
    return self;
}

@end

@implementation SZKHasher

+ (NSArray<NSString *> *)methodNames
{
    static NSArray<NSString *> *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray<NSString *> *list = [NSMutableArray array];
        for (const szk::HashMethodInfo &method : szk::HashMethods()) {
            [list addObject:@(method.name.c_str())];
        }
        names = list;
    });
    return names;
}

+ (SZKHashReport *)hashURLs:(NSArray<NSURL *> *)urls
                    methods:(NSArray<NSString *> *)methods
                   progress:(SZKProgressHandler)progress
                      error:(NSError **)error
{
    std::vector<std::string> inputs;
    for (NSURL *url in urls) {
        inputs.push_back(url.path.UTF8String ?: "");
    }
    std::vector<std::string> names;
    for (NSString *method in methods) {
        names.push_back(method.UTF8String);
    }

    szk::HashOutcome outcome;
    const szk::Result result = szk::HashFiles(inputs, names, SZKMakeProgressHandler(progress), outcome);
    // A report with a few unreadable files is still a report. Only a run
    // that could not start, or was cancelled, comes back empty-handed.
    if (!result.ok() && (outcome.items.empty() || result.status == szk::Status::cancelled)) {
        if (error) {
            *error = SZKErrorFromResult(result);
        }
        return nil;
    }
    return [[SZKHashReport alloc] initWithOutcome:outcome];
}

@end
