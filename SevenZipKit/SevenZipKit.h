//
//  SevenZipKit.h
//  SevenZipKit
//
//  Umbrella header. Pure Obj-C by design: the 7-Zip COM surface stays behind
//  the C++ core so that Swift never has to see it.
//

#import <Foundation/Foundation.h>

//! Project version number for SevenZipKit.
FOUNDATION_EXPORT double SevenZipKitVersionNumber;

//! Project version string for SevenZipKit.
FOUNDATION_EXPORT const unsigned char SevenZipKitVersionString[];

#import <SevenZipKit/SZKArchive.h>
#import <SevenZipKit/SZKArchiveEntry.h>
#import <SevenZipKit/SZKEngine.h>
#import <SevenZipKit/SZKError.h>
#import <SevenZipKit/SZKFormat.h>
#import <SevenZipKit/SZKHash.h>
#import <SevenZipKit/SZKOptions.h>
#import <SevenZipKit/SZKProgress.h>
