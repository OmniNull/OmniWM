// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

#import "OmniWMNowPlaying.h"

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <stdio.h>
#import <stdlib.h>
#import <unistd.h>

typedef void (*OmniRegister)(dispatch_queue_t);
typedef void (*OmniGetInfo)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*OmniGetPlaying)(dispatch_queue_t, void (^)(Boolean));
typedef void (*OmniGetPID)(dispatch_queue_t, void (^)(int));
typedef Boolean (*OmniSendCommand)(int, CFDictionaryRef);
typedef void (*OmniSetElapsed)(double);

static OmniGetInfo getInfo;
static OmniGetPlaying getPlaying;
static OmniGetPID getPID;
static OmniSendCommand sendCommand;
static OmniSetElapsed setElapsed;
static dispatch_queue_t queue;
static NSString *lastLine;
static uint64_t lastArtwork;
static NSMutableData *input;

static void *symbol(void *library, const char *name) {
    return library != NULL ? dlsym(library, name) : NULL;
}

static NSString *constant(void *library, const char *name) {
    CFStringRef *value = symbol(library, name);
    return value != NULL && *value != NULL ? (__bridge NSString *)*value : nil;
}

static uint64_t fingerprint(NSData *data) {
    uint64_t hash = 1469598103934665603ULL;
    const uint8_t *bytes = data.bytes;
    for (NSUInteger index = 0; index < data.length; index++) {
        hash = (hash ^ bytes[index]) * 1099511628211ULL;
    }
    return hash;
}

static void write_line(NSDictionary *payload) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];
    if (json == nil) {
        return;
    }
    NSString *line = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    if ([line isEqualToString:lastLine] && payload[@"artwork"] == nil) {
        return;
    }
    lastLine = line;
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static void emit(void) {
    getInfo(queue, ^(CFDictionaryRef raw) {
        NSDictionary *info = (__bridge NSDictionary *)raw;
        getPlaying(queue, ^(Boolean playing) {
            getPID(queue, ^(int pid) {
                NSMutableDictionary *payload = [NSMutableDictionary dictionary];
                payload[@"playing"] = @((BOOL)(playing != 0));
                payload[@"pid"] = @(pid);
                NSDictionary<NSString *, NSString *> *fields = @{
                    @"kMRMediaRemoteNowPlayingInfoTitle" : @"title",
                    @"kMRMediaRemoteNowPlayingInfoArtist" : @"artist",
                    @"kMRMediaRemoteNowPlayingInfoAlbum" : @"album",
                    @"kMRMediaRemoteNowPlayingInfoDuration" : @"duration",
                    @"kMRMediaRemoteNowPlayingInfoElapsedTime" : @"elapsed",
                    @"kMRMediaRemoteNowPlayingInfoPlaybackRate" : @"rate",
                    @"kMRMediaRemoteNowPlayingInfoShuffleMode" : @"shuffle",
                    @"kMRMediaRemoteNowPlayingInfoRepeatMode" : @"repeat"
                };
                for (NSString *key in fields) {
                    id value = info[key];
                    if ([value isKindOfClass:[NSString class]] || [value isKindOfClass:[NSNumber class]]) {
                        payload[fields[key]] = value;
                    }
                }
                id timestamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
                if ([timestamp isKindOfClass:[NSDate class]]) {
                    payload[@"sampledAt"] = @([(NSDate *)timestamp timeIntervalSince1970]);
                }
                id artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                if ([artwork isKindOfClass:[NSData class]] && [(NSData *)artwork length] > 0) {
                    uint64_t identity = fingerprint(artwork);
                    payload[@"artworkId"] = [NSString stringWithFormat:@"%016llx", identity];
                    if (identity != lastArtwork) {
                        lastArtwork = identity;
                        payload[@"artwork"] = [(NSData *)artwork base64EncodedStringWithOptions:0];
                    }
                } else {
                    lastArtwork = 0;
                }
                write_line(payload);
            });
        });
    });
}

static void perform(NSString *line) {
    NSArray<NSString *> *words = [line componentsSeparatedByString:@" "];
    NSDictionary<NSString *, NSNumber *> *commands = @{
        @"play" : @0, @"pause" : @1, @"toggle" : @2, @"next" : @4, @"previous" : @5, @"shuffle" : @6, @"repeat" : @7
    };
    NSNumber *command = commands[words.firstObject];
    if (command != nil && words.count == 1) {
        sendCommand(command.intValue, NULL);
    } else if ([words.firstObject isEqualToString:@"seek"] && words.count == 2 && setElapsed != NULL) {
        setElapsed(words[1].doubleValue);
    }
}

static void read_input(void) {
    uint8_t buffer[512];
    ssize_t count = read(STDIN_FILENO, buffer, sizeof buffer);
    if (count <= 0) {
        exit(0);
    }
    [input appendBytes:buffer length:(NSUInteger)count];
    while (true) {
        NSRange newline = [input rangeOfData:[NSData dataWithBytes:"\n" length:1] options:0
                                       range:NSMakeRange(0, input.length)];
        if (newline.location == NSNotFound) {
            break;
        }
        NSData *lineData = [input subdataWithRange:NSMakeRange(0, newline.location)];
        [input replaceBytesInRange:NSMakeRange(0, newline.location + 1) withBytes:NULL length:0];
        NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
        if (line != nil) {
            perform(line);
        }
    }
}

void omni_now_playing_run(void *interpreter, void *code) {
    (void)interpreter;
    (void)code;
    void *library = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
    OmniRegister registerForNotifications = symbol(library, "MRMediaRemoteRegisterForNowPlayingNotifications");
    getInfo = symbol(library, "MRMediaRemoteGetNowPlayingInfo");
    getPlaying = symbol(library, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    getPID = symbol(library, "MRMediaRemoteGetNowPlayingApplicationPID");
    sendCommand = symbol(library, "MRMediaRemoteSendCommand");
    setElapsed = symbol(library, "MRMediaRemoteSetElapsedTime");
    if (registerForNotifications == NULL || getInfo == NULL || getPlaying == NULL || getPID == NULL ||
        sendCommand == NULL) {
        fputs("{\"error\":\"unavailable\"}\n", stdout);
        fflush(stdout);
        exit(1);
    }
    queue = dispatch_queue_create("com.barut.OmniWM.now-playing", DISPATCH_QUEUE_SERIAL);
    input = [NSMutableData data];
    registerForNotifications(queue);
    const char *names[] = {
        "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
        "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
        "kMRMediaRemoteNowPlayingApplicationDidChangeNotification"
    };
    for (size_t index = 0; index < sizeof names / sizeof names[0]; index++) {
        NSString *name = constant(library, names[index]);
        if (name != nil) {
            [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil
                                                        usingBlock:^(NSNotification *notification) {
                (void)notification;
                dispatch_async(queue, ^{
                    emit();
                });
            }];
        }
    }
    dispatch_source_t reader = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, queue);
    dispatch_source_set_event_handler(reader, ^{
        read_input();
    });
    dispatch_resume(reader);
    dispatch_async(queue, ^{
        emit();
    });
    dispatch_main();
}
