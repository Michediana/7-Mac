//
//  SZKBridging.h
//  SevenZipKit
//
//  Obj-C++ glue shared by the façade's implementation files. Includes the C++
//  core headers, so it is Obj-C++ only -- but never the 7-Zip headers, which
//  is what keeps `typedef int BOOL` away from the Objective-C runtime's
//  `typedef bool BOOL`.
//

#ifndef SZKBridging_h
#define SZKBridging_h

#import <Foundation/Foundation.h>

#import "SZKArchiveCore.hpp"
#import "SZKError.h"
#import "SZKOptions.h"
#import "SZKProgress.h"

NS_ASSUME_NONNULL_BEGIN

/// 7-Zip hands back UTF-32LE, the native width of `wchar_t` here.
NSString *SZKStringFromText(const szk::Text &text);
szk::Text SZKTextFromString(NSString *string);

/// Nanoseconds since 1970 to a date; `nil` when the archive did not say.
NSDate *_Nullable SZKDateFromNanoseconds(bool has, int64_t nanoseconds);

NSError *SZKErrorFromResult(const szk::Result &result);
NSError *SZKErrorFromEntryFailure(const szk::EntryFailure &failure);

/// Builds the C++ handlers from the Objective-C blocks. The returned
/// std::functions capture the blocks, so they must not outlive the call.
szk::PasswordProvider SZKMakePasswordProvider(SZKPasswordProvider _Nullable provider);
szk::ProgressHandler SZKMakeProgressHandler(SZKProgressHandler _Nullable handler);
szk::OverwriteHandler SZKMakeOverwriteHandler(SZKOverwriteHandler _Nullable handler);

@interface SZKProgress ()
- (instancetype)initWithState:(const szk::Progress &)state;
@end

@interface SZKOverwriteRequest ()
- (instancetype)initWithRequest:(const szk::OverwriteRequest &)request;
@end

@interface SZKOutcome ()
- (instancetype)initWithExtractOutcome:(const szk::ExtractOutcome &)outcome;
/// `archiveSize` is the one figure only a create produces, so creation gets
/// its own initialiser rather than poking the property afterwards.
- (instancetype)initWithFileCount:(uint64_t)fileCount
                      folderCount:(uint64_t)folderCount
                      archiveSize:(uint64_t)archiveSize
                         failures:(const std::vector<szk::EntryFailure> &)failures;
@end

NS_ASSUME_NONNULL_END

#endif /* SZKBridging_h */
