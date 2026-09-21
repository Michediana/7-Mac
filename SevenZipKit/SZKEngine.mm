//
//  SZKEngine.mm
//  SevenZipKit
//
//  Objective-C façade over the C++ core. Nothing here includes a 7-Zip
//  header; see Internal/SZKEngineCore.hpp for why.
//

#import "SZKEngine.h"
#import "Internal/SZKFormat+Private.h"
#import "Internal/SZKEngineCore.hpp"

#pragma mark - Bridging

namespace {

/// 7-Zip hands back text as UTF-32LE, the native width of `wchar_t` here.
NSString *StringFromBytes(const szk::Bytes &bytes)
{
    if (bytes.empty()) {
        return @"";
    }
    NSString *string = [[NSString alloc] initWithBytes:bytes.data()
                                                length:bytes.size()
                                              encoding:NSUTF32LittleEndianStringEncoding];
    return string ?: @"";
}

NSData *DataFromBytes(const szk::Bytes &bytes)
{
    return [NSData dataWithBytes:bytes.data() length:bytes.size()];
}

/// Normalises one extension: lowercase, no leading dot. Upstream writes the
/// wrapped extension as ".tar" and uses "*" for "adds nothing".
NSString *NormalisedExtension(const szk::Text &text)
{
    NSString *value = StringFromBytes(text);
    if ([value hasPrefix:@"."]) {
        value = [value substringFromIndex:1];
    }
    return [value isEqualToString:@"*"] ? @"" : value.lowercaseString;
}

SZKFormat *MakeFormat(const szk::FormatInfo &info)
{
    NSMutableArray<NSString *> *extensions =
        [NSMutableArray arrayWithCapacity:info.extensions.size()];
    for (const szk::Text &extension : info.extensions) {
        [extensions addObject:NormalisedExtension(extension)];
    }

    NSMutableArray<NSString *> *addedExtensions =
        [NSMutableArray arrayWithCapacity:info.addedExtensions.size()];
    for (const szk::Text &added : info.addedExtensions) {
        [addedExtensions addObject:NormalisedExtension(added)];
    }

    NSMutableArray<NSData *> *signatures =
        [NSMutableArray arrayWithCapacity:info.signatures.size()];
    for (const szk::Bytes &signature : info.signatures) {
        [signatures addObject:DataFromBytes(signature)];
    }

    return [[SZKFormat alloc] initWithIndex:info.index
                                       name:StringFromBytes(info.name)
                             fileExtensions:extensions
                            addedExtensions:addedExtensions
                                   writable:info.writable
                                  keepsName:info.keepsName
                   supportsAlternateStreams:info.supportsAlternateStreams
                      supportsSymbolicLinks:info.supportsSymbolicLinks
                                      flags:info.flags
                                 signatures:signatures
                            signatureOffset:info.signatureOffset];
}

}  // namespace

#pragma mark - SZKEngine

@implementation SZKEngine

+ (NSArray<SZKFormat *> *)formats
{
    static NSArray<SZKFormat *> *formats;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const std::vector<szk::FormatInfo> &infos = szk::AllFormats();
        NSMutableArray<SZKFormat *> *collected = [NSMutableArray arrayWithCapacity:infos.size()];
        for (const szk::FormatInfo &info : infos) {
            [collected addObject:MakeFormat(info)];
        }
        formats = [collected copy];
    });
    return formats;
}

+ (NSArray<SZKFormat *> *)writableFormats
{
    static NSArray<SZKFormat *> *writable;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray<SZKFormat *> *collected = [NSMutableArray array];
        for (SZKFormat *format in self.formats) {
            if (format.isWritable) {
                [collected addObject:format];
            }
        }
        writable = [collected copy];
    });
    return writable;
}

+ (NSString *)upstreamVersion
{
    return @(szk::UpstreamVersion().c_str());
}

+ (NSString *)upstreamDate
{
    return @(szk::UpstreamDate().c_str());
}

+ (SZKFormat *)formatNamed:(NSString *)name
{
    for (SZKFormat *format in self.formats) {
        if ([format.name caseInsensitiveCompare:name] == NSOrderedSame) {
            return format;
        }
    }
    return nil;
}

+ (NSArray<SZKFormat *> *)formatsForFileExtension:(NSString *)fileExtension
{
    NSString *needle = [fileExtension hasPrefix:@"."] ? [fileExtension substringFromIndex:1]
                                                      : fileExtension;
    needle = needle.lowercaseString;
    if (needle.length == 0) {
        return @[];
    }

    NSMutableArray<SZKFormat *> *matches = [NSMutableArray array];
    for (SZKFormat *format in self.formats) {
        if ([format.fileExtensions containsObject:needle]) {
            [matches addObject:format];
        }
    }
    return matches;
}

@end
