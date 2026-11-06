// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

#import "OmniWMLayerCorners.h"
#import <objc/runtime.h>
#import <stdatomic.h>
#import <string.h>

@protocol OmniWMLayerContext <NSObject>
@property(nullable, retain) CALayer *layer;
@property(nullable) CGColorSpaceRef colorSpace;
+ (nullable instancetype)contextWithCGSConnection:(uint32_t)connection
                                          options:(nullable NSDictionary *)options;
- (void)invalidate;
@end

@protocol OmniWMWindowManagerCoordinator <NSObject>
- (void)performTransactionUsingBlock:(void (^)(id))block;
@end

@protocol OmniWMWindowManagerTransaction <NSObject>
- (void)addAction:(id)action;
@end

@protocol OmniWMWindowOrderingInfo <NSObject>
+ (id)infoWithWindow:(NSString *)window positioned:(NSUInteger)position relativeTo:(nullable NSString *)other;
- (void)setCGOtherWindowID:(uint32_t)windowID;
@end

@protocol OmniWMWindowTransactionAction <NSObject>
+ (id)actionForOrderingWindowWithInfo:(id)info fences:(nullable NSSet *)fences;
@end

@protocol OmniWMWindowRecord <NSObject>
- (NSString *)windowIdentifier;
@end

static _Atomic(void *) OmniWMCapturedWindowCoordinator;
static Method OmniWMCoordinatorCaptureMethod;
static IMP OmniWMCoordinatorOriginalImplementation;

static BOOL OmniWMLayerMethodMatches(Method method, const char *returnType,
                                    const char *argumentType) {
    if (method == NULL || method_getNumberOfArguments(method) != (argumentType ? 3 : 2)) {
        return NO;
    }
    NSMethodSignature *signature =
        [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    return strcmp(signature.methodReturnType, returnType) == 0 &&
           (argumentType == NULL ||
            strcmp([signature getArgumentTypeAtIndex:2], argumentType) == 0);
}

BOOL omniwm_layer_border_available(void) {
    static dispatch_once_t onceToken;
    static BOOL available;
    dispatch_once(&onceToken, ^{
        const struct {
            SEL getter;
            SEL setter;
            const char *type;
        } properties[] = {
            {@selector(cornerRadii), @selector(setCornerRadii:), @encode(CACornerRadii)},
            {@selector(rimColor), @selector(setRimColor:), @encode(CGColorRef)},
            {@selector(rimWidth), @selector(setRimWidth:), @encode(double)},
            {@selector(rimOpacity), @selector(setRimOpacity:), @encode(float)},
        };
        available = YES;
        for (size_t i = 0; i < sizeof(properties) / sizeof(properties[0]); i++) {
            if (!OmniWMLayerMethodMatches(
                    class_getInstanceMethod(CALayer.class, properties[i].getter),
                    properties[i].type, NULL) ||
                !OmniWMLayerMethodMatches(
                    class_getInstanceMethod(CALayer.class, properties[i].setter),
                    @encode(void), properties[i].type)) {
                available = NO;
                break;
            }
        }
        if (!available) {
            NSLog(@"[OmniWMLayerCorners] Native border layer API is unavailable or incompatible");
        }
    });
    return available;
}

NSObject *omniwm_layer_context_create(uint32_t connection, CALayer *layer) {
    Class contextClass = NSClassFromString(@"CAContext");
    if (![contextClass respondsToSelector:@selector(contextWithCGSConnection:options:)] ||
        ![contextClass instancesRespondToSelector:@selector(setLayer:)] ||
        ![contextClass instancesRespondToSelector:@selector(setColorSpace:)] ||
        ![contextClass instancesRespondToSelector:@selector(invalidate)]) {
        return nil;
    }
    id<OmniWMLayerContext> context =
        [(Class<OmniWMLayerContext>)contextClass contextWithCGSConnection:connection options:nil];
    context.layer = layer;
    return (NSObject *)context;
}

void omniwm_layer_context_set_color_space(NSObject *context, CGColorSpaceRef colorSpace) {
    ((id<OmniWMLayerContext>)context).colorSpace = colorSpace;
}

void omniwm_layer_context_invalidate(NSObject *context) {
    [(id<OmniWMLayerContext>)context invalidate];
}

void omniwm_window_manager_begin_coordinator_capture(void) {
    SEL selector = @selector(performTransactionUsingBlock:);
    Method method = class_getInstanceMethod(NSClassFromString(@"NSWMWindowCoordinator"), selector);
    if (method == NULL || OmniWMCoordinatorCaptureMethod != NULL ||
        atomic_load_explicit(&OmniWMCapturedWindowCoordinator, memory_order_acquire) != NULL) {
        return;
    }
    IMP original = method_getImplementation(method);
    OmniWMCoordinatorCaptureMethod = method;
    OmniWMCoordinatorOriginalImplementation = original;
    method_setImplementation(method, imp_implementationWithBlock(^(id coordinator, void (^body)(id)) {
        void *expected = NULL;
        void *retained = (__bridge_retained void *)coordinator;
        if (!atomic_compare_exchange_strong_explicit(
                &OmniWMCapturedWindowCoordinator, &expected, retained,
                memory_order_acq_rel, memory_order_acquire)) {
            CFRelease(retained);
        }
        ((void (*)(id, SEL, void (^)(id)))original)(coordinator, selector, body);
    }));
}

void omniwm_window_manager_end_coordinator_capture(void) {
    if (OmniWMCoordinatorCaptureMethod == NULL) {
        return;
    }
    method_setImplementation(OmniWMCoordinatorCaptureMethod, OmniWMCoordinatorOriginalImplementation);
    OmniWMCoordinatorCaptureMethod = NULL;
    OmniWMCoordinatorOriginalImplementation = NULL;
}

static id OmniWMIvarValue(id object, const char *name) {
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    return ivar == NULL ? nil : object_getIvar(object, ivar);
}

static NSString *OmniWMWindowManagerIdentifier(NSWindow *window) {
    id storage = OmniWMIvarValue(window, "_auxiliaryStorage");
    id record = storage == nil ? nil : OmniWMIvarValue(storage, "_wmWindow");
    return [record respondsToSelector:@selector(windowIdentifier)]
        ? [(id<OmniWMWindowRecord>)record windowIdentifier]
        : nil;
}

BOOL omniwm_window_manager_order(NSWindow *window, NSWindowOrderingMode place, uint32_t otherWindowID) {
    Class infoClass = NSClassFromString(@"WMWindowOrderingInfo");
    Class actionClass = NSClassFromString(@"WMWindowTransactionAction");
    void *coordinator = atomic_load_explicit(&OmniWMCapturedWindowCoordinator, memory_order_acquire);
    NSString *identifier = OmniWMWindowManagerIdentifier(window);
    if (coordinator == NULL || identifier == nil ||
        ![infoClass respondsToSelector:@selector(infoWithWindow:positioned:relativeTo:)] ||
        ![infoClass instancesRespondToSelector:@selector(setCGOtherWindowID:)] ||
        ![actionClass respondsToSelector:@selector(actionForOrderingWindowWithInfo:fences:)]) {
        return NO;
    }
    const NSUInteger position = place == NSWindowAbove ? 1 : 2;
    id<OmniWMWindowOrderingInfo> info =
        [(Class<OmniWMWindowOrderingInfo>)infoClass infoWithWindow:identifier positioned:position relativeTo:nil];
    [info setCGOtherWindowID:otherWindowID];
    id action = [(Class<OmniWMWindowTransactionAction>)actionClass actionForOrderingWindowWithInfo:info fences:nil];
    [(__bridge id<OmniWMWindowManagerCoordinator>)coordinator performTransactionUsingBlock:^(id transaction) {
        [(id<OmniWMWindowManagerTransaction>)transaction addAction:action];
    }];
    return YES;
}
