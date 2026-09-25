//
//  SZKOptions.mm
//  SevenZipKit
//

#import "SZKOptions.h"

@implementation SZKExtractOptions

- (instancetype)initWithDestinationDirectory:(NSURL *)destinationDirectory
{
    self = [super init];
    if (self) {
        _destinationDirectory = [destinationDirectory copy];
        _paths = SZKPathPolicyFullPaths;
        // Renaming the incoming file is the one default that cannot lose data.
        _overwrite = SZKOverwritePolicyAutoRename;
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone
{
    SZKExtractOptions *copy =
        [[SZKExtractOptions allocWithZone:zone] initWithDestinationDirectory:_destinationDirectory];
    copy.paths = _paths;
    copy.overwrite = _overwrite;
    copy.relativeToCommonParent = _relativeToCommonParent;
    return copy;
}

@end

@implementation SZKCreateOptions

- (instancetype)init
{
    self = [super init];
    if (self) {
        _level = SZKCompressionLevelNormal;
        _storesSymbolicLinks = YES;
        _storesHardLinks = YES;
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone
{
    SZKCreateOptions *copy = [[SZKCreateOptions allocWithZone:zone] init];
    copy.formatName = _formatName;
    copy.level = _level;
    copy.password = _password;
    copy.encryptsHeader = _encryptsHeader;
    copy.volumeSize = _volumeSize;
    copy.methodProperties = _methodProperties;
    copy.excludedNamePatterns = _excludedNamePatterns;
    copy.storesSymbolicLinks = _storesSymbolicLinks;
    copy.storesHardLinks = _storesHardLinks;
    return copy;
}

@end
