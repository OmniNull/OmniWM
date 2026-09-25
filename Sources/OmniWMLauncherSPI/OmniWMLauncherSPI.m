// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

#import "OmniWMLauncherSPI.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <dlfcn.h>

@interface OmniWMLSApplicationRecord : NSObject
+ (NSEnumerator *)enumeratorWithOptions:(NSUInteger)options;
- (NSString *)bundleIdentifier;
- (NSString *)localizedName;
- (NSURL *)URL;
- (BOOL)isPlaceholder;
- (BOOL)isLaunchProhibited;
- (id)_localizedName;
- (id)infoDictionary;
- (NSArray *)categoryTypesWithError:(NSError *__autoreleasing *)error;
@end

@interface OmniWMLSLocalizedString : NSObject
- (NSDictionary *)allStringValues;
@end

@interface OmniWMLSPropertyList : NSObject
- (id)objectForKey:(NSString *)key ofClass:(Class)valueClass;
@end

@interface NSImage (OmniWMPrivateSymbols)
+ (nullable NSImage *)imageWithPrivateSystemSymbolName:(NSString *)name
                              accessibilityDescription:(nullable NSString *)description;
@end

@interface CSAttributeEvaluator : NSObject
- (instancetype)initWithQuery:(NSString *)query
                    language:(NSString *)language
                       isCJK:(BOOL)isCJK
              fuzzyThreshold:(unsigned char)threshold
                     options:(NSUInteger)options;
- (void)setMatchOncePerTerm:(BOOL)value;
- (NSArray *)tokenizedQueryTerms;
@end

@interface PRSRankingItem : NSObject
+ (void)matchScoreTokensFromText:(NSString *)text
                  withEvaluator:(CSAttributeEvaluator *)evaluator
                    withHandler:(void (^)(NSArray<NSNumber *> *, NSUInteger, float, BOOL, BOOL, BOOL,
                                          NSUInteger))handler;
@end

@interface PRSRankingItemRanker : NSObject
+ (BOOL)isCJK;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (void)getKnowledgeUUID:(NSUUID *__autoreleasing *)uuid
       andSequenceNumber:(NSNumber *__autoreleasing *)sequence;
@end

@interface ATXAppDirectoryClient : NSObject
+ (NSDictionary<NSString *, NSNumber *> *)hardcodedAppCategoryMappings;
@end

@interface ATXAppDirectoryCategory : NSObject
+ (NSUInteger)appDirectoryCategoryForLSApplicationCategoryType:(NSString *)category;
+ (NSUInteger)parentCategoryForCategory:(NSUInteger)category;
+ (NSString *_Nullable)localizedStringForCategoryID:(NSUInteger)category;
@end

@interface ISIconFactory : NSObject
- (instancetype)initWithURL:(NSURL *)url;
- (void)prepareImagesForImageDescriptors:(NSArray *)descriptors;
- (CGImageRef _Nullable)CGImageForImageDescriptor:(id)descriptor;
@end

@interface ISImageDescriptor : NSObject
- (instancetype)initWithSize:(CGSize)size scale:(CGFloat)scale;
@end

@interface OmniWMLauncherAppRecord ()
- (instancetype)initWithPath:(NSString *)path
           bundleIdentifier:(NSString *)bundleIdentifier
                displayName:(NSString *)displayName
             alternateNames:(NSArray<NSString *> *)alternateNames
                   category:(NSString *_Nullable)category;
@end

@implementation OmniWMLauncherAppRecord

- (instancetype)initWithPath:(NSString *)path
           bundleIdentifier:(NSString *)bundleIdentifier
                displayName:(NSString *)displayName
             alternateNames:(NSArray<NSString *> *)alternateNames
                   category:(NSString *_Nullable)category {
    self = [super init];
    if (self) {
        _path = [path copy];
        _bundleIdentifier = [bundleIdentifier copy];
        _displayName = [displayName copy];
        _alternateNames = [alternateNames copy];
        _category = [category copy];
    }
    return self;
}

@end

typedef NSString *_Nullable (*OmniWMUnquoteFunction)(NSString *);
typedef CFStringRef _Nullable (*OmniWMCreateQueryStringFunction)(CFStringRef _Nullable, CFStringRef);
typedef void (*OmniWMSetQueryBoolFunction)(MDQueryRef, Boolean);

typedef struct {
    OmniWMCreateQueryStringFunction createQueryString;
    OmniWMSetQueryBoolFunction setMatchesSupportFiles;
    OmniWMSetQueryBoolFunction setMatchesOnlyFinderFiles;
    CFStringRef *scopeMyFiles;
    CFStringRef *menuRelevance;
} OmniWMMetadataAPI;

static BOOL OmniWMEnsureLaunchServices(void) {
    static dispatch_once_t onceToken;
    static BOOL loaded;
    dispatch_once(&onceToken, ^{
        loaded = dlopen(
            "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/LaunchServices",
            RTLD_NOW | RTLD_LOCAL) != NULL;
    });
    return loaded;
}

static BOOL OmniWMEnsureCategories(void) {
    static dispatch_once_t onceToken;
    static BOOL loaded;
    dispatch_once(&onceToken, ^{
        loaded = dlopen(
            "/System/Library/PrivateFrameworks/AppPredictionClient.framework/AppPredictionClient",
            RTLD_NOW | RTLD_LOCAL) != NULL;
    });
    return loaded;
}

static BOOL OmniWMEnsureIcons(void) {
    static dispatch_once_t onceToken;
    static BOOL loaded;
    dispatch_once(&onceToken, ^{
        loaded = dlopen("/System/Library/PrivateFrameworks/IconServices.framework/IconServices",
                        RTLD_NOW | RTLD_LOCAL) != NULL;
    });
    return loaded;
}

static NSDictionary<NSString *, NSNumber *> *_Nullable OmniWMCategoryMappings(void) {
    static dispatch_once_t onceToken;
    static NSDictionary<NSString *, NSNumber *> *mappings;
    dispatch_once(&onceToken, ^{
        if (OmniWMEnsureCategories()) {
            Class clientClass = NSClassFromString(@"ATXAppDirectoryClient");
            if ([clientClass respondsToSelector:@selector(hardcodedAppCategoryMappings)]) {
                id value = [(id)clientClass hardcodedAppCategoryMappings];
                if ([value isKindOfClass:NSDictionary.class]) {
                    mappings = [value copy];
                }
            }
        }
    });
    return mappings;
}

static BOOL OmniWMEnsureRankingFramework(void) {
    static dispatch_once_t onceToken;
    static BOOL loaded;
    dispatch_once(&onceToken, ^{
        void *handle = dlopen(
            "/System/Library/PrivateFrameworks/SpotlightServices.framework/SpotlightServices",
            RTLD_NOW | RTLD_LOCAL);
        loaded = handle != NULL;
    });
    return loaded;
}

static OmniWMUnquoteFunction OmniWMUnquote(void) {
    static dispatch_once_t onceToken;
    static OmniWMUnquoteFunction function;
    dispatch_once(&onceToken, ^{
        if (OmniWMEnsureRankingFramework()) {
            function = (OmniWMUnquoteFunction)dlsym(RTLD_DEFAULT, "SSPhraseQueryUnquoteString");
        }
    });
    return function;
}

static const OmniWMMetadataAPI *OmniWMMetadata(void) {
    static dispatch_once_t onceToken;
    static OmniWMMetadataAPI api;
    dispatch_once(&onceToken, ^{
        void *handle = dlopen(
            "/System/Library/Frameworks/CoreServices.framework/Frameworks/Metadata.framework/Metadata",
            RTLD_NOW | RTLD_LOCAL);
        if (handle) {
            api.createQueryString =
                (OmniWMCreateQueryStringFunction)dlsym(handle, "_MDQueryCreateQueryString");
            api.setMatchesSupportFiles =
                (OmniWMSetQueryBoolFunction)dlsym(handle, "MDQuerySetMatchesSupportFiles");
            api.setMatchesOnlyFinderFiles =
                (OmniWMSetQueryBoolFunction)dlsym(handle, "_MDQuerySetMatchesOnlyFinderFiles");
            api.scopeMyFiles = (CFStringRef *)dlsym(handle, "kMDQueryScopeMyFiles");
            api.menuRelevance = (CFStringRef *)dlsym(handle, "kMDQueryResultMenuRelevance");
        }
    });
    return &api;
}

static void OmniWMAddName(id value, NSMutableOrderedSet<NSString *> *names) {
    if ([value isKindOfClass:NSString.class] && [value length] > 0) {
        [names addObject:value];
    } else if ([value isKindOfClass:NSDictionary.class]) {
        OmniWMAddName(value[@"INAlternativeAppName"], names);
    }
}

static void OmniWMAddInfoNames(OmniWMLSApplicationRecord *record, NSMutableOrderedSet<NSString *> *names) {
    if (![record respondsToSelector:@selector(infoDictionary)]) {
        return;
    }
    id info = [record infoDictionary];
    if (![info respondsToSelector:@selector(objectForKey:ofClass:)]) {
        return;
    }
    for (NSString *key in @[ @"CFBundleAlternateNames", @"INAlternativeAppNames" ]) {
        id values = [(OmniWMLSPropertyList *)info objectForKey:key ofClass:NSArray.class];
        if ([values isKindOfClass:NSArray.class]) {
            for (id value in values) {
                OmniWMAddName(value, names);
            }
        }
    }
}

static void OmniWMAddLocalizedNames(OmniWMLSApplicationRecord *record, NSMutableOrderedSet<NSString *> *names) {
    if (![record respondsToSelector:@selector(_localizedName)]) {
        return;
    }
    id localized = [record _localizedName];
    if (![localized respondsToSelector:@selector(allStringValues)]) {
        return;
    }
    NSDictionary *values = [(OmniWMLSLocalizedString *)localized allStringValues];
    if (![values isKindOfClass:NSDictionary.class]) {
        return;
    }
    NSMutableArray<NSString *> *strings = [NSMutableArray arrayWithCapacity:values.count];
    for (id value in values.allValues) {
        if ([value isKindOfClass:NSString.class] && [value length] > 0) {
            [strings addObject:value];
        }
    }
    [names addObjectsFromArray:[strings sortedArrayUsingSelector:@selector(compare:)]];
}

static NSString *_Nullable OmniWMRecordCategory(OmniWMLSApplicationRecord *record) {
    if (![record respondsToSelector:@selector(categoryTypesWithError:)]) {
        return nil;
    }
    NSArray *types = [record categoryTypesWithError:nil];
    id first = [types isKindOfClass:NSArray.class] ? types.firstObject : nil;
    return [first isKindOfClass:UTType.class] ? [(UTType *)first identifier] : nil;
}

static OmniWMLauncherAppRecord *_Nullable OmniWMAppRecordFromLS(id item) {
    if (![item respondsToSelector:@selector(bundleIdentifier)] || ![item respondsToSelector:@selector(URL)] ||
        ![item respondsToSelector:@selector(localizedName)]) {
        return nil;
    }
    OmniWMLSApplicationRecord *record = item;
    if (([record respondsToSelector:@selector(isPlaceholder)] && [record isPlaceholder]) ||
        ([record respondsToSelector:@selector(isLaunchProhibited)] && [record isLaunchProhibited])) {
        return nil;
    }
    NSString *bundleIdentifier = [record bundleIdentifier];
    NSURL *url = [record URL];
    NSString *displayName = [record localizedName];
    if (![bundleIdentifier isKindOfClass:NSString.class] || bundleIdentifier.length == 0 ||
        ![url isKindOfClass:NSURL.class] || !url.isFileURL || ![displayName isKindOfClass:NSString.class] ||
        displayName.length == 0) {
        return nil;
    }
    NSMutableOrderedSet<NSString *> *names = [NSMutableOrderedSet orderedSet];
    OmniWMAddInfoNames(record, names);
    OmniWMAddLocalizedNames(record, names);
    [names removeObject:displayName];
    return [[OmniWMLauncherAppRecord alloc] initWithPath:url.path
                                        bundleIdentifier:bundleIdentifier
                                             displayName:displayName
                                          alternateNames:names.array
                                                category:OmniWMRecordCategory(record)];
}

NSArray<OmniWMLauncherAppRecord *> *_Nullable omniwm_launcher_copy_app_records(void) {
    NSArray<OmniWMLauncherAppRecord *> *result = nil;
    @autoreleasepool {
        @try {
            if (!OmniWMEnsureLaunchServices()) {
                return nil;
            }
            Class recordClass = NSClassFromString(@"LSApplicationRecord");
            if (![recordClass respondsToSelector:@selector(enumeratorWithOptions:)]) {
                return nil;
            }
            NSEnumerator *enumerator = [(id)recordClass enumeratorWithOptions:0];
            if (![enumerator isKindOfClass:NSEnumerator.class]) {
                return nil;
            }
            NSMutableArray<OmniWMLauncherAppRecord *> *records = [NSMutableArray array];
            for (id item in enumerator) {
                @autoreleasepool {
                    OmniWMLauncherAppRecord *record = OmniWMAppRecordFromLS(item);
                    if (record) {
                        [records addObject:record];
                    }
                }
            }
            result = [records copy];
        } @catch (NSException *exception) {
            return nil;
        }
    }
    return result;
}

NSString *_Nullable omniwm_launcher_database_fingerprint(uint64_t *sequence) {
    NSString *result = nil;
    @autoreleasepool {
        @try {
            if (sequence) {
                *sequence = 0;
            }
            if (!sequence || !OmniWMEnsureLaunchServices()) {
                return nil;
            }
            Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
            if (![workspaceClass respondsToSelector:@selector(defaultWorkspace)]) {
                return nil;
            }
            LSApplicationWorkspace *workspace = [(id)workspaceClass defaultWorkspace];
            if (![workspace respondsToSelector:@selector(getKnowledgeUUID:andSequenceNumber:)]) {
                return nil;
            }
            NSUUID *uuid = nil;
            NSNumber *number = nil;
            [workspace getKnowledgeUUID:&uuid andSequenceNumber:&number];
            if (![uuid isKindOfClass:NSUUID.class] || ![number isKindOfClass:NSNumber.class]) {
                return nil;
            }
            *sequence = number.unsignedLongLongValue;
            result = uuid.UUIDString;
        } @catch (NSException *exception) {
            return nil;
        }
    }
    return result;
}

NSString *_Nullable omniwm_launcher_app_category(NSString *bundleIdentifier,
                                                  NSString *_Nullable lsCategory) {
    NSString *result = nil;
    @autoreleasepool {
        @try {
            if (!OmniWMEnsureCategories()) {
                return nil;
            }
            Class categoryClass = NSClassFromString(@"ATXAppDirectoryCategory");
            if (![categoryClass respondsToSelector:
                                   @selector(appDirectoryCategoryForLSApplicationCategoryType:)] ||
                ![categoryClass respondsToSelector:@selector(parentCategoryForCategory:)]) {
                return nil;
            }
            NSNumber *hardcoded = OmniWMCategoryMappings()[bundleIdentifier];
            NSUInteger category = [hardcoded isKindOfClass:NSNumber.class]
                                      ? hardcoded.unsignedIntegerValue
                                      : 0;
            if (category == 0 && [lsCategory isKindOfClass:NSString.class]) {
                category = [(id)categoryClass appDirectoryCategoryForLSApplicationCategoryType:lsCategory];
            }
            if (category == 0) {
                return nil;
            }
            for (NSUInteger depth = 0; depth < 4 && category >= 6000; depth++) {
                NSUInteger parent = [(id)categoryClass parentCategoryForCategory:category];
                if (parent == 0 || parent == category) {
                    break;
                }
                category = parent;
            }
            if (category >= 6000 || category == 1008) {
                return nil;
            }
            result = [NSString stringWithFormat:@"%lu", (unsigned long)category];
        } @catch (NSException *exception) {
            return nil;
        }
    }
    return result;
}

NSString *_Nullable omniwm_launcher_category_name(NSString *categoryIdentifier) {
    NSString *result = nil;
    @autoreleasepool {
        @try {
            if (![categoryIdentifier isKindOfClass:NSString.class] || !OmniWMEnsureCategories()) {
                return nil;
            }
            Class categoryClass = NSClassFromString(@"ATXAppDirectoryCategory");
            if (![categoryClass respondsToSelector:@selector(localizedStringForCategoryID:)]) {
                return nil;
            }
            NSUInteger category = categoryIdentifier.integerValue;
            NSString *name = [(id)categoryClass localizedStringForCategoryID:category];
            result = [name isKindOfClass:NSString.class] && name.length > 0 ? name : nil;
        } @catch (NSException *exception) {
            return nil;
        }
    }
    return result;
}

CGImageRef _Nullable omniwm_launcher_create_icon(CFURLRef url, CGFloat points, CGFloat scale) {
    @autoreleasepool {
        @try {
            if (!url || points <= 0 || scale <= 0) {
                return NULL;
            }
            NSURL *fileURL = [(__bridge NSURL *)url URLByResolvingSymlinksInPath];
            if (OmniWMEnsureIcons()) {
                Class factoryClass = NSClassFromString(@"ISIconFactory");
                Class descriptorClass = NSClassFromString(@"ISImageDescriptor");
                if ([factoryClass instancesRespondToSelector:@selector(initWithURL:)] &&
                    [descriptorClass instancesRespondToSelector:@selector(initWithSize:scale:)]) {
                    ISIconFactory *icon = [[(id)factoryClass alloc] initWithURL:fileURL];
                    ISImageDescriptor *descriptor = [[(id)descriptorClass alloc]
                        initWithSize:CGSizeMake(points, points) scale:scale];
                    if (icon && descriptor &&
                        [icon respondsToSelector:@selector(prepareImagesForImageDescriptors:)] &&
                        [icon respondsToSelector:@selector(CGImageForImageDescriptor:)]) {
                        [icon prepareImagesForImageDescriptors:@[ descriptor ]];
                        CGImageRef image = [icon CGImageForImageDescriptor:descriptor];
                        if (image) {
                            return CGImageRetain(image);
                        }
                    }
                }
            }
            NSImage *icon = [NSWorkspace.sharedWorkspace iconForFile:fileURL.path];
            if (!icon) {
                return NULL;
            }
            CGRect rect = CGRectMake(0, 0, points, points);
            CGImageRef image = [icon CGImageForProposedRect:&rect context:nil hints:nil];
            return image ? CGImageRetain(image) : NULL;
        } @catch (NSException *exception) {
            return NULL;
        }
    }
}

NSImage *_Nullable omniwm_launcher_private_symbol(NSString *name) {
    NSImage *result = nil;
    @autoreleasepool {
        @try {
            if (![name isKindOfClass:NSString.class] ||
                ![NSImage respondsToSelector:@selector(imageWithPrivateSystemSymbolName:
                                                            accessibilityDescription:)]) {
                return nil;
            }
            result = [NSImage imageWithPrivateSystemSymbolName:name accessibilityDescription:nil];
        } @catch (NSException *exception) {
            return nil;
        }
    }
    return result;
}

void *_Nullable omniwm_spotlight_evaluator_create(NSString *query, NSString *language) {
    @autoreleasepool {
        @try {
            if (![query isKindOfClass:NSString.class] || ![language isKindOfClass:NSString.class] ||
                !OmniWMEnsureRankingFramework()) {
                return NULL;
            }
            Class evaluatorClass = NSClassFromString(@"CSAttributeEvaluator");
            if (![evaluatorClass instancesRespondToSelector:
                                    @selector(initWithQuery:language:isCJK:fuzzyThreshold:options:)]) {
                return NULL;
            }
            OmniWMUnquoteFunction unquote = OmniWMUnquote();
            NSString *unquoted = unquote ? unquote(query) : query;
            Class rankerClass = NSClassFromString(@"PRSRankingItemRanker");
            BOOL isCJK = [rankerClass respondsToSelector:@selector(isCJK)]
                             ? [(id)rankerClass isCJK]
                             : NO;
            CSAttributeEvaluator *evaluator = [[(id)evaluatorClass alloc]
                initWithQuery:unquoted ?: query
                     language:language.length > 0 ? language : @"en"
                        isCJK:isCJK
               fuzzyThreshold:0
                      options:0];
            if (!evaluator || ![evaluator respondsToSelector:@selector(setMatchOncePerTerm:)]) {
                return NULL;
            }
            [evaluator setMatchOncePerTerm:NO];
            return (void *)CFBridgingRetain(evaluator);
        } @catch (NSException *exception) {
            return NULL;
        }
    }
}

void omniwm_spotlight_evaluator_release(void *_Nullable evaluator) {
    @autoreleasepool {
        @try {
            if (evaluator) {
                id object = CFBridgingRelease(evaluator);
                (void)object;
            }
        } @catch (NSException *exception) {
        }
    }
}

NSUInteger omniwm_spotlight_query_term_count(void *_Nullable evaluator) {
    @autoreleasepool {
        @try {
            if (!evaluator) {
                return 0;
            }
            id object = (__bridge id)evaluator;
            if (![object respondsToSelector:@selector(tokenizedQueryTerms)]) {
                return 0;
            }
            NSArray *terms = [object tokenizedQueryTerms];
            return [terms isKindOfClass:NSArray.class] ? terms.count : 0;
        } @catch (NSException *exception) {
            return 0;
        }
    }
}

BOOL omniwm_spotlight_match(void *_Nullable evaluator, NSString *text, OmniWMTokenMatch *outMatch) {
    @autoreleasepool {
        @try {
            if (outMatch) {
                *outMatch = (OmniWMTokenMatch){0};
            }
            if (!evaluator || !outMatch || ![text isKindOfClass:NSString.class] ||
                !OmniWMEnsureRankingFramework()) {
                return NO;
            }
            Class itemClass = NSClassFromString(@"PRSRankingItem");
            if (![itemClass respondsToSelector:
                               @selector(matchScoreTokensFromText:withEvaluator:withHandler:)]) {
                return NO;
            }
            id object = (__bridge id)evaluator;
            __block BOOL called = NO;
            OmniWMTokenMatch *result = outMatch;
            [(id)itemClass matchScoreTokensFromText:text
                                      withEvaluator:object
                                        withHandler:^(NSArray<NSNumber *> *indices,
                                                      NSUInteger tokenCount, float fraction,
                                                      BOOL adjacent, BOOL first, BOOL last,
                                                      NSUInteger distinct) {
                called = YES;
                result->tokenCount = tokenCount;
                result->matchFraction = fraction;
                result->adjacentInOrder = adjacent;
                result->firstTokenMatched = first;
                result->lastTokenMatched = last;
                result->distinctMatchedTokenCount = distinct;
                NSUInteger termIndex = 0;
                for (NSNumber *index in indices) {
                    if ([index isKindOfClass:NSNumber.class] && index.integerValue >= 0) {
                        result->matchedTermCount++;
                        if (termIndex < 64) {
                            result->matchedTermMask |= 1ULL << termIndex;
                        }
                    }
                    termIndex++;
                }
            }];
            return called;
        } @catch (NSException *exception) {
            return NO;
        }
    }
}

CFStringRef _Nullable omniwm_mdquery_create_query_string(CFStringRef text) {
    @autoreleasepool {
        @try {
            OmniWMCreateQueryStringFunction create = OmniWMMetadata()->createQueryString;
            return text && create ? create(NULL, text) : NULL;
        } @catch (NSException *exception) {
            return NULL;
        }
    }
}

CFStringRef _Nullable omniwm_mdquery_scope_my_files(void) {
    @autoreleasepool {
        @try {
            CFStringRef *scope = OmniWMMetadata()->scopeMyFiles;
            return scope && *scope ? CFRetain(*scope) : NULL;
        } @catch (NSException *exception) {
            return NULL;
        }
    }
}

CFStringRef _Nullable omniwm_mdquery_menu_relevance_attribute(void) {
    @autoreleasepool {
        @try {
            CFStringRef *attribute = OmniWMMetadata()->menuRelevance;
            return attribute && *attribute ? CFRetain(*attribute) : NULL;
        } @catch (NSException *exception) {
            return NULL;
        }
    }
}

BOOL omniwm_mdquery_set_matches_support_files(MDQueryRef query, BOOL matches) {
    @autoreleasepool {
        @try {
            OmniWMSetQueryBoolFunction set = OmniWMMetadata()->setMatchesSupportFiles;
            if (!query || !set) {
                return NO;
            }
            set(query, matches);
            return YES;
        } @catch (NSException *exception) {
            return NO;
        }
    }
}

BOOL omniwm_mdquery_set_matches_only_finder_files(MDQueryRef query, BOOL matches) {
    @autoreleasepool {
        @try {
            OmniWMSetQueryBoolFunction set = OmniWMMetadata()->setMatchesOnlyFinderFiles;
            if (!query || !set) {
                return NO;
            }
            set(query, matches);
            return YES;
        } @catch (NSException *exception) {
            return NO;
        }
    }
}

CFDictionaryRef _Nullable omniwm_mdquery_copy_result_attributes(MDQueryRef query, CFIndex index,
                                                                  CFArrayRef attributes) {
    CFDictionaryRef result = NULL;
    @autoreleasepool {
        @try {
            if (!query || !attributes || index < 0 || index >= MDQueryGetResultCount(query)) {
                return NULL;
            }
            MDItemRef item = (MDItemRef)MDQueryGetResultAtIndex(query, index);
            NSMutableDictionary<NSString *, id> *values = [NSMutableDictionary dictionary];
            for (id name in (__bridge NSArray *)attributes) {
                if (![name isKindOfClass:NSString.class]) {
                    continue;
                }
                id value = nil;
                if ([name isEqualToString:(__bridge NSString *)kMDItemPath]) {
                    value = item ? CFBridgingRelease(MDItemCopyAttribute(item, kMDItemPath)) : nil;
                } else {
                    value = (__bridge id)MDQueryGetAttributeValueOfResultAtIndex(
                        query, (__bridge CFStringRef)name, index);
                }
                if (value) {
                    values[name] = value;
                }
            }
            result = (CFDictionaryRef)CFBridgingRetain(values);
        } @catch (NSException *exception) {
            return NULL;
        }
    }
    return result;
}

uint32_t omniwm_launcher_spi_status(void) {
    @autoreleasepool {
        @try {
            uint32_t status = 0;
            if (OmniWMEnsureLaunchServices()) {
                if ([NSClassFromString(@"LSApplicationRecord") respondsToSelector:@selector(enumeratorWithOptions:)]) {
                    status |= OmniWMLauncherSPIApps;
                }
                Class workspace = NSClassFromString(@"LSApplicationWorkspace");
                if ([workspace respondsToSelector:@selector(defaultWorkspace)] &&
                    [workspace instancesRespondToSelector:
                                   @selector(getKnowledgeUUID:andSequenceNumber:)]) {
                    status |= OmniWMLauncherSPIFingerprint;
                }
            }
            if (OmniWMEnsureCategories()) {
                Class category = NSClassFromString(@"ATXAppDirectoryCategory");
                if ([category respondsToSelector:@selector(appDirectoryCategoryForLSApplicationCategoryType:)] &&
                    [category respondsToSelector:@selector(localizedStringForCategoryID:)]) {
                    status |= OmniWMLauncherSPICategories;
                }
            }
            if (OmniWMEnsureIcons()) {
                Class factory = NSClassFromString(@"ISIconFactory");
                if ([factory instancesRespondToSelector:@selector(initWithURL:)]) {
                    status |= OmniWMLauncherSPIIcons;
                }
            }
            if (OmniWMEnsureRankingFramework()) {
                Class evaluator = NSClassFromString(@"CSAttributeEvaluator");
                Class item = NSClassFromString(@"PRSRankingItem");
                if ([evaluator instancesRespondToSelector:
                                   @selector(initWithQuery:language:isCJK:fuzzyThreshold:options:)]) {
                    status |= OmniWMLauncherSPIEvaluator;
                }
                if ([item respondsToSelector:
                              @selector(matchScoreTokensFromText:withEvaluator:withHandler:)]) {
                    status |= OmniWMLauncherSPIMatcher;
                }
            }
            const OmniWMMetadataAPI *metadata = OmniWMMetadata();
            if (metadata->createQueryString && metadata->setMatchesSupportFiles &&
                metadata->setMatchesOnlyFinderFiles) {
                status |= OmniWMLauncherSPIMDQuery;
            }
            if (metadata->scopeMyFiles && *metadata->scopeMyFiles) {
                status |= OmniWMLauncherSPIMDScope;
            }
            return status;
        } @catch (NSException *exception) {
            return 0;
        }
    }
}
