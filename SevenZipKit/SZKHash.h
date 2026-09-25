//
//  SZKHash.h
//  SevenZipKit
//
//  Checksums, computed by the engine's own hashers — the figures `7zz h`
//  prints, for files on disk and for the entries inside an archive.
//

#import <Foundation/Foundation.h>

#import <SevenZipKit/SZKOptions.h>

NS_ASSUME_NONNULL_BEGIN

/// One file or folder's checksums.
@interface SZKHashedItem : NSObject
/// Relative to the input's parent for files on disk; the entry path for an
/// archive.
@property (nonatomic, readonly, copy) NSString *path;
@property (nonatomic, readonly) BOOL isDirectory;
@property (nonatomic, readonly) uint64_t size;
/// One per method, in the report's `methods` order; empty for a folder.
///
/// Written as 7-Zip writes them: digests of 8 bytes or fewer (CRC32, CRC64,
/// XXH64) as an upper-case number, longer ones as lower-case bytes, the way
/// `shasum` prints them. Compare case-insensitively.
@property (nonatomic, readonly, copy) NSArray<NSString *> *digests;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface SZKHashReport : NSObject
/// The methods used, as the engine names them.
@property (nonatomic, readonly, copy) NSArray<NSString *> *methods;
@property (nonatomic, readonly, copy) NSArray<SZKHashedItem *> *items;
/// 7-Zip's "sum of data": one figure per method over every file.
@property (nonatomic, readonly, copy) NSArray<NSString *> *dataSums;
@property (nonatomic, readonly) uint64_t fileCount;
@property (nonatomic, readonly) uint64_t byteCount;
/// Files that could not be read, or entries that did not decode.
@property (nonatomic, readonly, copy) NSArray<NSError *> *failures;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface SZKHasher : NSObject

/// Every method the engine has, e.g. `CRC32`, `SHA256`, `BLAKE2sp`.
@property (class, nonatomic, readonly) NSArray<NSString *> *methodNames;

/// Hashes files and folders (recursively). Links are hashed as links.
+ (nullable SZKHashReport *)hashURLs:(NSArray<NSURL *> *)urls
                             methods:(NSArray<NSString *> *)methods
                            progress:(nullable SZKProgressHandler)progress
                               error:(NSError **)error;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
