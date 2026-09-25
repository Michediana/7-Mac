//
//  SZKArchive.h
//  SevenZipKit
//

#import <Foundation/Foundation.h>

#import <SevenZipKit/SZKOptions.h>

@class SZKArchiveEntry;
@class SZKHashReport;

NS_ASSUME_NONNULL_BEGIN

/// An open archive.
///
/// Opening reads the entry list, so `entries` is ready immediately and costs
/// nothing to read again. Everything happens in this process: there is no
/// subprocess, and the password is never written anywhere.
///
/// Not thread-safe. 7-Zip's handlers keep position state on the underlying
/// stream, so one archive object belongs to one thread at a time. Opening the
/// same file twice to work on it concurrently is fine.
@interface SZKArchive : NSObject

/// Opens the archive at `url`.
///
/// Returns `nil` with `SZKErrorPasswordRequired` if the archive's entry list
/// is encrypted and `passwordProvider` is `nil` or declines.
+ (nullable instancetype)archiveAtURL:(NSURL *)url
                     passwordProvider:(nullable SZKPasswordProvider)passwordProvider
                                error:(NSError **)error;

/// The file this archive was opened from.
@property (nonatomic, readonly, copy) NSURL *url;

/// Name of the handler that opened it, e.g. `7z`.
@property (nonatomic, readonly, copy) NSString *formatName;
/// Index into `SZKEngine.formats`.
@property (nonatomic, readonly) NSUInteger formatIndex;
/// Bytes the archive occupies, when the handler reports it.
@property (nonatomic, readonly, nullable) NSNumber *physicalSize;
/// The entry list itself was encrypted.
@property (nonatomic, readonly) BOOL hasEncryptedHeader;
/// Number of volume files; 1 for an ordinary archive.
@property (nonatomic, readonly) NSUInteger volumeCount;
/// The volumes beyond the one that was opened.
@property (nonatomic, readonly, copy) NSArray<NSURL *> *additionalVolumeURLs;

@property (nonatomic, readonly, copy) NSArray<SZKArchiveEntry *> *entries;

/// For an archive opened out of another one: the archive it lives in, and
/// the entry path it has there. `nil` for an archive opened from a file.
@property (nonatomic, readonly, nullable) SZKArchive *parentArchive;
@property (nonatomic, readonly, copy, nullable) NSString *pathInParent;

/// Opens entry `index` as an archive, reading it in place through this
/// archive's own stream.
///
/// Works where the handler can seek inside an entry — tar, iso, dmg, cpio, ar
/// and similar containers. Formats that compress their entries (7z, zip,
/// gzip…) cannot, and fail with `SZKErrorUnsupported`: extract the entry to a
/// file and open that instead.
///
/// The result keeps this archive alive and reads through it, so the two share
/// its thread restriction: use them from one thread at a time, together.
- (nullable SZKArchive *)openEntryAtIndex:(NSUInteger)index
                         passwordProvider:(nullable SZKPasswordProvider)passwordProvider
                                    error:(NSError **)error;

/// Extracts `indexes`, or everything when `indexes` is `nil`.
///
/// Selection is by index, not by name pattern: picking three entries out of
/// forty thousand costs three entries' worth of work.
///
/// Returns `NO` on failure, having still filled in `outcome`. Entries that
/// failed while the run carried on are in `outcome.entryErrors`.
- (BOOL)extractIndexes:(nullable NSIndexSet *)indexes
               options:(SZKExtractOptions *)options
              progress:(nullable SZKProgressHandler)progress
      passwordProvider:(nullable SZKPasswordProvider)passwordProvider
      overwriteHandler:(nullable SZKOverwriteHandler)overwriteHandler
               outcome:(SZKOutcome *_Nullable *_Nullable)outcome
                 error:(NSError **)error;

/// Decodes `indexes` (everything when `nil`) and checksums each entry as it
/// goes, writing nothing: a test that also says what it saw. The report is
/// returned even when some entries failed; they are in its `failures`.
- (nullable SZKHashReport *)hashIndexes:(nullable NSIndexSet *)indexes
                                methods:(NSArray<NSString *> *)methods
                               progress:(nullable SZKProgressHandler)progress
                       passwordProvider:(nullable SZKPasswordProvider)passwordProvider
                                  error:(NSError **)error;

/// Decodes and verifies without writing anything.
- (BOOL)testIndexes:(nullable NSIndexSet *)indexes
           progress:(nullable SZKProgressHandler)progress
   passwordProvider:(nullable SZKPasswordProvider)passwordProvider
            outcome:(SZKOutcome *_Nullable *_Nullable)outcome
              error:(NSError **)error;

#pragma mark - Rewriting

/// Why this archive cannot be changed, or `nil` when it can. A format with no
/// writer (rar, zstd…), a set of volumes, or an archive reached through
/// another container all say so here — ask before offering an edit.
@property (nonatomic, readonly, copy, nullable) NSString *reasonNotModifiable;

// The three edits below never touch the archive they are called on. Each
// writes a complete new archive to `destinationURL` — which must not exist —
// copying unchanged entries as they are, still compressed where the format
// allows. Putting it in place of the original is the caller's move, and is
// what makes an edit cancellable and undoable.
//
// `password` decodes existing encrypted entries where the format has to, and
// encrypts added ones; pass `nil` for an archive with nothing encrypted.

/// Everything except the entries at `indexes`. A folder's contents are
/// separate entries: pass them too, or they stay.
- (BOOL)writeDeletingIndexes:(NSIndexSet *)indexes
                       toURL:(NSURL *)destinationURL
                    password:(nullable NSString *)password
                    progress:(nullable SZKProgressHandler)progress
                     outcome:(SZKOutcome *_Nullable *_Nullable)outcome
                       error:(NSError **)error;

/// The same entries, with the ones in `newPaths` (index → '/'-separated
/// archive path) under new names. Nothing is recompressed.
- (BOOL)writeRenaming:(NSDictionary<NSNumber *, NSString *> *)newPaths
                toURL:(NSURL *)destinationURL
             password:(nullable NSString *)password
             progress:(nullable SZKProgressHandler)progress
              outcome:(SZKOutcome *_Nullable *_Nullable)outcome
                error:(NSError **)error;

/// The same entries plus `sourceURLs` (scanned recursively) under
/// `folderPath` ('/'-separated, empty for the root). A file whose path is
/// already taken replaces the entry — or, with `onlyIfNewer`, only when its
/// modification date is later.
- (BOOL)writeAddingURLs:(NSArray<NSURL *> *)sourceURLs
               inFolder:(NSString *)folderPath
            onlyIfNewer:(BOOL)onlyIfNewer
                  toURL:(NSURL *)destinationURL
               password:(nullable NSString *)password
               progress:(nullable SZKProgressHandler)progress
                outcome:(SZKOutcome *_Nullable *_Nullable)outcome
                  error:(NSError **)error;

#pragma mark - Creating

/// Creates an archive at `url` from `sourceURLs` (files or folders, scanned
/// recursively). Paths are stored relative to each source's parent, so adding
/// `/a/b/tree` stores `tree/…`.
///
/// Fails if anything already exists at `url`.
+ (BOOL)createArchiveAtURL:(NSURL *)url
                fromURLs:(NSArray<NSURL *> *)sourceURLs
                   options:(SZKCreateOptions *)options
                  progress:(nullable SZKProgressHandler)progress
                   outcome:(SZKOutcome *_Nullable *_Nullable)outcome
                     error:(NSError **)error;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
