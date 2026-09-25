// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

#import <AppKit/AppKit.h>
#import <CoreServices/CoreServices.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface OmniWMLauncherAppRecord : NSObject

@property(nonatomic, copy, readonly) NSString *path;
@property(nonatomic, copy, readonly) NSString *bundleIdentifier;
@property(nonatomic, copy, readonly) NSString *displayName;
@property(nonatomic, copy, readonly) NSArray<NSString *> *alternateNames;
@property(nonatomic, copy, readonly, nullable) NSString *category;

@end

typedef struct {
    NSUInteger tokenCount;
    NSUInteger matchedTermCount;
    NSUInteger distinctMatchedTokenCount;
    float matchFraction;
    BOOL adjacentInOrder;
    BOOL firstTokenMatched;
    BOOL lastTokenMatched;
    uint64_t matchedTermMask;
} OmniWMTokenMatch;

enum {
    OmniWMLauncherSPIApps = 1u << 0,
    OmniWMLauncherSPIEvaluator = 1u << 1,
    OmniWMLauncherSPIMatcher = 1u << 2,
    OmniWMLauncherSPIMDQuery = 1u << 3,
    OmniWMLauncherSPIMDScope = 1u << 4,
    OmniWMLauncherSPIFingerprint = 1u << 5,
    OmniWMLauncherSPICategories = 1u << 6,
    OmniWMLauncherSPIIcons = 1u << 7
};

NSArray<OmniWMLauncherAppRecord *> *_Nullable omniwm_launcher_copy_app_records(void);
NSString *_Nullable omniwm_launcher_database_fingerprint(uint64_t *sequence);
NSString *_Nullable omniwm_launcher_app_category(NSString *bundleIdentifier,
                                                  NSString *_Nullable lsCategory);
NSString *_Nullable omniwm_launcher_category_name(NSString *categoryIdentifier);
CGImageRef _Nullable omniwm_launcher_create_icon(CFURLRef url, CGFloat points,
                                                  CGFloat scale) CF_RETURNS_RETAINED;
NSImage *_Nullable omniwm_launcher_private_symbol(NSString *name);

void *_Nullable omniwm_spotlight_evaluator_create(NSString *query, NSString *language);
void omniwm_spotlight_evaluator_release(void *_Nullable evaluator);
NSUInteger omniwm_spotlight_query_term_count(void *_Nullable evaluator);
BOOL omniwm_spotlight_match(void *_Nullable evaluator, NSString *text, OmniWMTokenMatch *outMatch);

CFStringRef _Nullable omniwm_mdquery_create_query_string(CFStringRef text) CF_RETURNS_RETAINED;
CFStringRef _Nullable omniwm_mdquery_scope_my_files(void) CF_RETURNS_RETAINED;
CFStringRef _Nullable omniwm_mdquery_menu_relevance_attribute(void) CF_RETURNS_RETAINED;
BOOL omniwm_mdquery_set_matches_support_files(MDQueryRef query, BOOL matches);
BOOL omniwm_mdquery_set_matches_only_finder_files(MDQueryRef query, BOOL matches);
CFDictionaryRef _Nullable omniwm_mdquery_copy_result_attributes(MDQueryRef query, CFIndex index,
                                                                  CFArrayRef attributes) CF_RETURNS_RETAINED;

uint32_t omniwm_launcher_spi_status(void);

NS_ASSUME_NONNULL_END
