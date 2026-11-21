// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

#import "OmniWMWiFiSPI.h"

#import <CoreWLAN/CoreWLAN.h>
#import <dlfcn.h>

@interface NSObject (OmniWMWiFiSPI)
- (NSInteger)serviceType;
- (id)coreWiFiScanResult;
- (id)coreWiFiNetworkProfile;
- (id)scanRecord;
- (NSData *)SSID;
- (BOOL)isSystemMode;
- (BOOL)isPSK;
- (void)setScanResult:(id)scanResult;
- (void)setKnownNetworkProfile:(id)profile;
- (BOOL)associateWithParameters:(id)parameters error:(NSError **)error;
@end

NSString *const OmniWMWiFiErrorDomain = @"com.barut.OmniWM.wifi";

static const NSInteger OmniWMWiFiCoreWLANXPCService = 5;

static BOOL fail(NSError **error, OmniWMWiFiError code) {
    if (error) {
        *error = [NSError errorWithDomain:OmniWMWiFiErrorDomain code:code userInfo:nil];
    }
    return NO;
}

static BOOL responds(id object, SEL selector) {
    return object != nil && [object respondsToSelector:selector];
}

static BOOL loadCoreWiFi(void) {
    static BOOL loaded;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        loaded = dlopen("/System/Library/PrivateFrameworks/CoreWiFi.framework/CoreWiFi", RTLD_NOW) != NULL;
    });
    return loaded;
}

static CWNetworkProfile *savedProfile(CWConfiguration *configuration, NSData *ssid) {
    CWNetworkProfile *match = nil;
    for (CWNetworkProfile *profile in configuration.networkProfiles) {
        if (![profile.ssidData isEqualToData:ssid]) {
            continue;
        }
        if (match && match.security != profile.security) {
            return nil;
        }
        match = profile;
    }
    return match;
}

static NSArray<CWNetwork *> *named(NSSet<CWNetwork *> *networks, NSData *ssid) {
    NSPredicate *matching = [NSPredicate predicateWithBlock:^BOOL(CWNetwork *network, NSDictionary *bindings) {
        (void)bindings;
        return [network.ssidData isEqualToData:ssid];
    }];
    return [[networks.allObjects filteredArrayUsingPredicate:matching]
        sortedArrayUsingComparator:^NSComparisonResult(CWNetwork *a, CWNetwork *b) {
            return a.rssiValue > b.rssiValue ? NSOrderedAscending
                : a.rssiValue < b.rssiValue ? NSOrderedDescending : NSOrderedSame;
        }];
}

static id eligibleScan(NSArray<CWNetwork *> *networks, CWNetworkProfile *saved, NSData *ssid) {
    for (CWNetwork *network in networks) {
        if (![network supportsSecurity:saved.security] || !responds(network, @selector(coreWiFiScanResult))) {
            continue;
        }
        id scan = [network coreWiFiScanResult];
        if (responds(scan, @selector(scanRecord)) && responds(scan, @selector(isPSK)) &&
            responds(scan, @selector(SSID)) && [scan scanRecord] && [scan isPSK] &&
            [[scan SSID] isEqualToData:ssid]) {
            return scan;
        }
    }
    return nil;
}

static BOOL join(NSData *ssid, NSError **error) {
    if (!loadCoreWiFi()) {
        return fail(error, OmniWMWiFiErrorUnavailable);
    }
    CWInterface *interface = [CWWiFiClient sharedWiFiClient].interface;
    Class parametersClass = NSClassFromString(@"CWFAssocParameters");
    if (!interface || !parametersClass) {
        return fail(error, OmniWMWiFiErrorUnavailable);
    }
    id corewifi = [interface valueForKey:@"corewifi"];
    if (!responds(corewifi, @selector(serviceType)) || [corewifi serviceType] != OmniWMWiFiCoreWLANXPCService ||
        !responds(corewifi, @selector(associateWithParameters:error:))) {
        return fail(error, OmniWMWiFiErrorUnavailable);
    }
    CWNetworkProfile *saved = savedProfile(interface.configuration, ssid);
    if (!saved || !responds(saved, @selector(coreWiFiNetworkProfile))) {
        return fail(error, OmniWMWiFiErrorNotEligible);
    }
    id profile = [saved coreWiFiNetworkProfile];
    if (!responds(profile, @selector(isSystemMode)) || !responds(profile, @selector(isPSK)) ||
        !responds(profile, @selector(SSID)) || ![profile isSystemMode] || ![profile isPSK] ||
        ![[profile SSID] isEqualToData:ssid]) {
        return fail(error, OmniWMWiFiErrorNotEligible);
    }
    NSArray<CWNetwork *> *networks = named(interface.cachedScanResults, ssid);
    id scan = eligibleScan(networks, saved, ssid);
    if (!scan) {
        NSError *scanError = nil;
        NSSet<CWNetwork *> *fresh = [interface scanForNetworksWithSSID:ssid error:&scanError];
        if (!fresh) {
            return fail(error, OmniWMWiFiErrorUnavailable);
        }
        networks = named(fresh, ssid);
        scan = eligibleScan(networks, saved, ssid);
    }
    if (networks.count == 0) {
        return fail(error, OmniWMWiFiErrorNotInRange);
    }
    if (!scan) {
        return fail(error, OmniWMWiFiErrorNotEligible);
    }
    id parameters = [[parametersClass alloc] init];
    if (!responds(parameters, @selector(setScanResult:)) || !responds(parameters, @selector(setKnownNetworkProfile:))) {
        return fail(error, OmniWMWiFiErrorUnavailable);
    }
    [parameters setScanResult:scan];
    [parameters setKnownNetworkProfile:profile];
    return [corewifi associateWithParameters:parameters error:error];
}

BOOL omniwm_wifi_join_known_network(NSData *ssid, NSError **error) {
    @try {
        return join(ssid, error);
    } @catch (NSException *exception) {
        (void)exception;
        return fail(error, OmniWMWiFiErrorUnavailable);
    }
}
