// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const OmniWMWiFiErrorDomain;

typedef NS_ENUM(NSInteger, OmniWMWiFiError) {
    OmniWMWiFiErrorUnavailable = 1,
    OmniWMWiFiErrorNotInRange = 2,
    OmniWMWiFiErrorNotEligible = 3,
};

BOOL omniwm_wifi_join_known_network(NSData *ssid, NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
