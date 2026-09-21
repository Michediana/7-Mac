//
//  SZKFormat+Private.h
//  SevenZipKit
//

#import "SZKFormat.h"

NS_ASSUME_NONNULL_BEGIN

@interface SZKFormat ()

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
              signatureOffset:(uint32_t)signatureOffset NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
