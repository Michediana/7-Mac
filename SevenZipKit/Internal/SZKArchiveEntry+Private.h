//
//  SZKArchiveEntry+Private.h
//  SevenZipKit
//

#import "SZKArchiveEntry.h"

#import "SZKArchiveCore.hpp"

NS_ASSUME_NONNULL_BEGIN

@interface SZKArchiveEntry ()
- (instancetype)initWithEntry:(const szk::EntryInfo &)entry NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END
