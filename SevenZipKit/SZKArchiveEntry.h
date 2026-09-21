//
//  SZKArchiveEntry.h
//  SevenZipKit
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One entry inside an archive.
///
/// The optional-number properties are optional for a reason: many formats
/// leave sizes, checksums or timestamps undefined, and zero is a real value.
/// `nil` means "the archive does not say".
@interface SZKArchiveEntry : NSObject

/// Position in the archive. This is what you pass back to extract a subset.
@property (nonatomic, readonly) NSUInteger index;

/// Path as stored, '/'-separated and relative to the archive root.
@property (nonatomic, readonly, copy) NSString *path;

@property (nonatomic, readonly) BOOL isDirectory;
@property (nonatomic, readonly) BOOL isSymbolicLink;
/// The entry's contents are encrypted. With an encrypted header the whole
/// entry list is too, and the archive will not open without the password.
@property (nonatomic, readonly) BOOL isEncrypted;

@property (nonatomic, readonly, nullable) NSNumber *uncompressedSize;
@property (nonatomic, readonly, nullable) NSNumber *compressedSize;
/// CRC32 as stored, for formats that keep one.
@property (nonatomic, readonly, nullable) NSNumber *checksum;

@property (nonatomic, readonly, nullable) NSDate *modificationDate;
@property (nonatomic, readonly, nullable) NSDate *creationDate;
@property (nonatomic, readonly, nullable) NSDate *accessDate;

/// POSIX mode bits, for archives written by Unix tools.
@property (nonatomic, readonly, nullable) NSNumber *posixPermissions;

/// Compression method as the engine names it, e.g. `LZMA2:24`. May be empty.
@property (nonatomic, readonly, copy) NSString *method;

/// `compressedSize / uncompressedSize`, or `nil` when either is unknown or
/// the entry is empty.
@property (nonatomic, readonly, nullable) NSNumber *compressionRatio;

@end

NS_ASSUME_NONNULL_END
