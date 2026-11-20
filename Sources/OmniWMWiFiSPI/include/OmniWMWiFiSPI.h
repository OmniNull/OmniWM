// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const OmniWMWiFiErrorDomain;

typedef NS_ENUM(NSInteger, OmniWMWiFiError) {
    /// CoreWiFi or one of the private selectors the join needs is missing on this macOS.
    OmniWMWiFiErrorUnavailable = 1,
    /// No scan result for the SSID is in range.
    OmniWMWiFiErrorNotInRange = 2,
    /// The SSID has no single saved system-mode personal (PSK) profile that matches what is in range.
    OmniWMWiFiErrorNotEligible = 3,
};

/// Joins a saved personal network without reading its password. CoreWiFi hands the saved profile and a real scan
/// result to airportd, which looks the password up in the System keychain itself. Blocks for the scan and the
/// association; call it off the main thread. Errors outside OmniWMWiFiErrorDomain come from CoreWiFi.
BOOL omniwm_wifi_join_known_network(NSData *ssid, NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
