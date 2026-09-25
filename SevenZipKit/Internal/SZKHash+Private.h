//
//  SZKHash+Private.h
//  SevenZipKit
//

#import "SZKHash.h"

#import "SZKHashCore.hpp"

NS_ASSUME_NONNULL_BEGIN

@interface SZKHashedItem ()
- (instancetype)initWithItem:(const szk::HashedItem &)item;
@end

@interface SZKHashReport ()
- (instancetype)initWithOutcome:(const szk::HashOutcome &)outcome;
@end

NS_ASSUME_NONNULL_END
