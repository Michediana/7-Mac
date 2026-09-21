//
//  SZKEngine.h
//  SevenZipKit
//
//  Entry point to the embedded 7-Zip engine.
//

#import <Foundation/Foundation.h>

@class SZKFormat;

NS_ASSUME_NONNULL_BEGIN

/// The 7-Zip engine compiled into this framework.
///
/// There is no library to locate and no subprocess to spawn: the engine is
/// statically linked into `SevenZipKit`, and `SevenZipKit` itself is the
/// dynamic library. Everything here is thread-safe and lazily initialised on
/// first use.
@interface SZKEngine : NSObject

/// Upstream 7-Zip version, e.g. `26.03`.
@property (class, nonatomic, readonly) NSString *upstreamVersion;

/// Upstream release date, e.g. `2026-09-03`.
@property (class, nonatomic, readonly) NSString *upstreamDate;

/// Every format handler the engine registers, in engine order.
@property (class, nonatomic, readonly) NSArray<SZKFormat *> *formats;

/// The subset of `formats` that can be written.
@property (class, nonatomic, readonly) NSArray<SZKFormat *> *writableFormats;

/// Look a format up by its engine name, case-insensitively. Returns `nil` for
/// an unknown name.
+ (nullable SZKFormat *)formatNamed:(NSString *)name NS_SWIFT_NAME(format(named:));

/// Formats claiming `fileExtension` (given with or without a leading dot).
/// More than one format can claim the same extension.
+ (NSArray<SZKFormat *> *)formatsForFileExtension:(NSString *)fileExtension;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
