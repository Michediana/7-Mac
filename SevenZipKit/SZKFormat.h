//
//  SZKFormat.h
//  SevenZipKit
//
//  One archive format as the engine describes it.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A format handler registered in the engine. Immutable and cheap to keep.
@interface SZKFormat : NSObject

/// Position of the handler in `SZKEngine.formats`. The engine sorts its
/// handlers by name, so this is stable for a given engine build but carries no
/// meaning beyond identifying the handler.
@property (nonatomic, readonly) NSUInteger index;

/// Handler name, e.g. `7z`, `zip`, `Ext`. Not localised: it is an identifier.
@property (nonatomic, readonly, copy) NSString *name;

/// File extensions the handler claims, lowercase and without a leading dot.
/// May be empty: some handlers are reached by signature only.
@property (nonatomic, readonly, copy) NSArray<NSString *> *fileExtensions;

/// Whether the engine can *write* this format. Only 7 of the 60 can.
///
/// Read this rather than hardcoding a list: `zstd` in particular reads but does
/// not write, and neither does RAR.
@property (nonatomic, readonly, getter=isWritable) BOOL writable;

/// The handler keeps the archive's inner name for a single-file archive.
@property (nonatomic, readonly) BOOL keepsName;

/// The handler exposes alternate data streams.
@property (nonatomic, readonly) BOOL supportsAlternateStreams;

/// The handler represents symbolic links.
@property (nonatomic, readonly) BOOL supportsSymbolicLinks;

/// Raw `kFlags` bitfield, for the few callers that need it.
@property (nonatomic, readonly) uint32_t flags;

/// Magic byte sequences identifying the format. A handler may have several, or
/// none at all.
@property (nonatomic, readonly, copy) NSArray<NSData *> *signatures;

/// Byte offset at which `signatures` are expected.
@property (nonatomic, readonly) uint32_t signatureOffset;

/// The extension this format adds when it wraps another, for `fileExtensions`
/// at the same position: `gzip` answers `tar` for `tgz`, so `archive.tgz`
/// unwraps to `archive.tar`. Returns `nil` where the format adds nothing.
- (nullable NSString *)wrappedExtensionForFileExtension:(NSString *)fileExtension;

@end

NS_ASSUME_NONNULL_END
