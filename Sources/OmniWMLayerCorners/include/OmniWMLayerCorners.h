// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct CACornerRadii {
    CGSize topLeft;
    CGSize topRight;
    CGSize bottomRight;
    CGSize bottomLeft;
} CACornerRadii;

@interface CALayer (OmniWMLayerCorners)
@property(nonatomic) CACornerRadii cornerRadii NS_SWIFT_MAIN_ACTOR;
@property(nullable, nonatomic) CGColorRef rimColor NS_SWIFT_MAIN_ACTOR;
@property(nonatomic) double rimWidth NS_SWIFT_MAIN_ACTOR;
@property(nonatomic) float rimOpacity NS_SWIFT_MAIN_ACTOR;
@end

BOOL omniwm_layer_border_available(void);

NSObject *_Nullable omniwm_layer_context_create(uint32_t connection, CALayer *layer) NS_SWIFT_MAIN_ACTOR;
void omniwm_layer_context_set_color_space(NSObject *context, _Nullable CGColorSpaceRef colorSpace) NS_SWIFT_MAIN_ACTOR;
void omniwm_layer_context_invalidate(NSObject *context) NS_SWIFT_MAIN_ACTOR;

void omniwm_window_manager_begin_coordinator_capture(void) NS_SWIFT_MAIN_ACTOR;
void omniwm_window_manager_end_coordinator_capture(void) NS_SWIFT_MAIN_ACTOR;
BOOL omniwm_window_manager_order(NSWindow *window, NSWindowOrderingMode place, uint32_t otherWindowID) NS_SWIFT_MAIN_ACTOR;

NS_ASSUME_NONNULL_END
