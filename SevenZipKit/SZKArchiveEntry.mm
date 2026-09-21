//
//  SZKArchiveEntry.mm
//  SevenZipKit
//

#import "SZKArchiveEntry.h"
#import "Internal/SZKArchiveEntry+Private.h"
#import "Internal/SZKBridging.h"

@implementation SZKArchiveEntry

- (instancetype)initWithEntry:(const szk::EntryInfo &)entry
{
    self = [super init];
    if (self) {
        _index = entry.index;
        _path = SZKStringFromText(entry.path);
        _isDirectory = entry.isDirectory;
        _isSymbolicLink = entry.isSymbolicLink;
        _isEncrypted = entry.isEncrypted;
        _uncompressedSize = entry.hasSize ? @(entry.size) : nil;
        _compressedSize = entry.hasPackedSize ? @(entry.packedSize) : nil;
        _checksum = entry.hasCRC ? @(entry.crc) : nil;
        _modificationDate = SZKDateFromNanoseconds(entry.hasModified, entry.modified);
        _creationDate = SZKDateFromNanoseconds(entry.hasCreated, entry.created);
        _accessDate = SZKDateFromNanoseconds(entry.hasAccessed, entry.accessed);
        // Only the permission bits; the file-type bits are already reflected
        // in isDirectory and isSymbolicLink.
        _posixPermissions = entry.hasPosixMode ? @(entry.posixMode & 07777) : nil;
        _method = SZKStringFromText(entry.method);
    }
    return self;
}

- (NSNumber *)compressionRatio
{
    if (!_uncompressedSize || !_compressedSize || _uncompressedSize.unsignedLongLongValue == 0) {
        return nil;
    }
    return @((double)_compressedSize.unsignedLongLongValue /
             (double)_uncompressedSize.unsignedLongLongValue);
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@ %@%@%@>",
            NSStringFromClass(self.class), self.path,
            self.isDirectory ? @"/" : @"",
            self.isEncrypted ? @" encrypted" : @""];
}

@end
