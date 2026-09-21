//
//  SZKOptions.h
//  SevenZipKit
//

#import <Foundation/Foundation.h>

@class SZKProgress;

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Extraction

typedef NS_ENUM(NSInteger, SZKPathPolicy) {
    /// Keep the archive's directory structure.
    SZKPathPolicyFullPaths = 0,
    /// Drop directories; write every file straight into the destination.
    SZKPathPolicyFlatten
};

typedef NS_ENUM(NSInteger, SZKOverwritePolicy) {
    /// Call the overwrite handler. With no handler, nothing is overwritten.
    SZKOverwritePolicyAsk = 0,
    SZKOverwritePolicyOverwrite,
    SZKOverwritePolicySkip,
    /// Rename the incoming file.
    SZKOverwritePolicyAutoRename,
    /// Rename what is already on disk.
    SZKOverwritePolicyRenameExisting
};

typedef NS_ENUM(NSInteger, SZKOverwriteDecision) {
    SZKOverwriteDecisionOverwrite = 0,
    SZKOverwriteDecisionOverwriteAll,
    SZKOverwriteDecisionSkip,
    SZKOverwriteDecisionSkipAll,
    SZKOverwriteDecisionAutoRename,
    SZKOverwriteDecisionCancel
};

/// A file already exists where an entry wants to go.
@interface SZKOverwriteRequest : NSObject
@property (nonatomic, readonly, copy) NSString *existingPath;
@property (nonatomic, readonly, nullable) NSNumber *existingSize;
@property (nonatomic, readonly, nullable) NSDate *existingModificationDate;
@property (nonatomic, readonly, copy) NSString *incomingPath;
@property (nonatomic, readonly, nullable) NSNumber *incomingSize;
@property (nonatomic, readonly, nullable) NSDate *incomingModificationDate;
@end

@interface SZKExtractOptions : NSObject <NSCopying>
/// Where to write. Created if it does not exist.
@property (nonatomic, copy) NSURL *destinationDirectory;
@property (nonatomic) SZKPathPolicy paths;
@property (nonatomic) SZKOverwritePolicy overwrite;

- (instancetype)initWithDestinationDirectory:(NSURL *)destinationDirectory;
- (instancetype)init NS_UNAVAILABLE;
@end

#pragma mark - Creation

/// 7-Zip's own scale, passed through as the `-mx` property.
typedef NS_ENUM(NSInteger, SZKCompressionLevel) {
    SZKCompressionLevelStore   = 0,
    SZKCompressionLevelFastest = 1,
    SZKCompressionLevelFast    = 3,
    SZKCompressionLevelNormal  = 5,
    SZKCompressionLevelMaximum = 7,
    SZKCompressionLevelUltra   = 9
};

@interface SZKCreateOptions : NSObject <NSCopying>

/// Engine format name, e.g. `7z` or `zip`. `nil` means: infer it from the
/// archive's extension.
///
/// Only the seven writable formats work; ask `SZKEngine.writableFormats`
/// instead of assuming. `gzip`, `bzip2` and `xz` hold exactly one file — hand
/// them a folder and you get `SZKErrorUnsupported`.
@property (nonatomic, copy, nullable) NSString *formatName;

@property (nonatomic) SZKCompressionLevel level;

/// `nil` for no encryption. The password is handed to the engine through a
/// callback: it never reaches a command line, a temporary file or the disk.
@property (nonatomic, copy, nullable) NSString *password;

/// Encrypt the entry list as well, so the archive will not open without the
/// password. 7z only.
@property (nonatomic) BOOL encryptsHeader;

/// Split the output into volumes of this many bytes. 0 writes one file.
@property (nonatomic) uint64_t volumeSize;

/// Raw `-m` properties for anything above does not cover, e.g.
/// `@{@"m": @"PPMd", @"s": @"off"}`. Applied last, so these win.
@property (nonatomic, copy, nullable) NSDictionary<NSString *, NSString *> *methodProperties;

@end

#pragma mark - Outcomes

/// What an operation actually did. Reported even when it ends in an error,
/// because a run that wrote 900 of 1000 files is worth describing.
@interface SZKOutcome : NSObject
@property (nonatomic, readonly) uint64_t fileCount;
@property (nonatomic, readonly) uint64_t folderCount;
/// Bytes of the files written, or verified when testing.
@property (nonatomic, readonly) uint64_t byteCount;
/// Bytes the engine decoded. Larger than `byteCount` for a partial extract
/// from a solid archive, which has to decode a whole block to reach one entry.
@property (nonatomic, readonly) uint64_t processedByteCount;
/// Size of the finished archive, for a create.
@property (nonatomic, readonly) uint64_t archiveSize;
/// One `NSError` per entry that failed while the run carried on.
@property (nonatomic, readonly, copy) NSArray<NSError *> *entryErrors;
@end

#pragma mark - Handlers

/// Return `nil` to cancel.
typedef NSString *_Nullable (^SZKPasswordProvider)(void);
/// Return `NO` to cancel.
typedef BOOL (^SZKProgressHandler)(SZKProgress *progress);
typedef SZKOverwriteDecision (^SZKOverwriteHandler)(SZKOverwriteRequest *request);

NS_ASSUME_NONNULL_END
