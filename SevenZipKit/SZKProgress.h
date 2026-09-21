//
//  SZKProgress.h
//  SevenZipKit
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// How far along an operation is.
///
/// These are byte counts, not a percentage: the engine reports real totals
/// through `IProgress`, which is one of the reasons this app embeds the
/// library instead of parsing a command line tool's output.
@interface SZKProgress : NSObject

/// Total bytes the engine expects to process, 0 until it knows.
@property (nonatomic, readonly) uint64_t totalBytes;
@property (nonatomic, readonly) uint64_t completedBytes;

/// 0...1, or `nil` while the total is still unknown.
@property (nonatomic, readonly, nullable) NSNumber *fractionCompleted;

/// The entry being worked on, empty between entries.
@property (nonatomic, readonly, copy) NSString *currentPath;
@property (nonatomic, readonly) BOOL currentIsDirectory;

@end

NS_ASSUME_NONNULL_END
