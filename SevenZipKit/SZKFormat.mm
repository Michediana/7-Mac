//
//  SZKFormat.mm
//  SevenZipKit
//

#import "Internal/SZKFormat+Private.h"

@implementation SZKFormat {
    /// Runs parallel to `fileExtensions`; an empty string means "adds nothing".
    NSArray<NSString *> *_addedExtensions;
}

- (instancetype)initWithIndex:(NSUInteger)index
                         name:(NSString *)name
               fileExtensions:(NSArray<NSString *> *)fileExtensions
              addedExtensions:(NSArray<NSString *> *)addedExtensions
                     writable:(BOOL)writable
                    keepsName:(BOOL)keepsName
     supportsAlternateStreams:(BOOL)supportsAlternateStreams
        supportsSymbolicLinks:(BOOL)supportsSymbolicLinks
                        flags:(uint32_t)flags
                   signatures:(NSArray<NSData *> *)signatures
              signatureOffset:(uint32_t)signatureOffset
{
    self = [super init];
    if (self) {
        _index = index;
        _name = [name copy];
        _fileExtensions = [fileExtensions copy];
        _addedExtensions = [addedExtensions copy];
        _writable = writable;
        _keepsName = keepsName;
        _supportsAlternateStreams = supportsAlternateStreams;
        _supportsSymbolicLinks = supportsSymbolicLinks;
        _flags = flags;
        _signatures = [signatures copy];
        _signatureOffset = signatureOffset;
    }
    return self;
}

- (NSString *)wrappedExtensionForFileExtension:(NSString *)fileExtension
{
    NSString *needle = [fileExtension hasPrefix:@"."] ? [fileExtension substringFromIndex:1]
                                                      : fileExtension;
    const NSUInteger position = [self.fileExtensions indexOfObject:needle.lowercaseString];
    if (position == NSNotFound || position >= _addedExtensions.count) {
        return nil;
    }
    NSString *wrapped = _addedExtensions[position];
    return wrapped.length > 0 ? wrapped : nil;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@ %@ %@ ext:%@>",
            NSStringFromClass(self.class),
            self.name,
            self.isWritable ? @"rw" : @"ro",
            self.fileExtensions.count ? [self.fileExtensions componentsJoinedByString:@","] : @"-"];
}

@end
