//
//  SZKError.h
//  SevenZipKit
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const SZKErrorDomain;

/// Why an operation did not succeed.
///
/// `SZKErrorPasswordWrong` and `SZKErrorDamaged` are genuinely hard to tell
/// apart for an encrypted archive — the engine cannot distinguish a bad key
/// from bad data — so the engine reports the password case whenever a password
/// was involved at all.
typedef NS_ERROR_ENUM(SZKErrorDomain, SZKError) {
    /// A handler returned an error we have no better name for.
    SZKErrorFailed = 1,
    /// A progress or password handler asked to stop.
    SZKErrorCancelled,
    /// Encrypted, and no password was available.
    SZKErrorPasswordRequired,
    /// A password was supplied and did not work.
    SZKErrorPasswordWrong,
    /// No handler recognised the file.
    SZKErrorNotAnArchive,
    /// The file or destination could not be opened, read or written.
    SZKErrorUnreadable,
    /// Recognised, but the data is broken.
    SZKErrorDamaged,
    /// Recognised, but this build cannot do what was asked.
    SZKErrorUnsupported,
};

NS_ASSUME_NONNULL_END
