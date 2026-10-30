// Pembaca Now Playing macOS untuk pemutar selain Spotify dan Music (YouTube Music di Meiro, Chrome, Safari, dll.).
//
// Sejak macOS 15.4, MediaRemote hanya memberi data Now Playing ke program milik Apple. Karena itu pustaka ini
// tidak dimuat oleh Lyricsbar sendiri, tapi oleh /usr/bin/perl bawaan macOS (lihat NowPlayingSource di main.swift).
//
// Keluaran: satu baris JSON setiap kali lagu atau statusnya berubah; {} = tidak ada yang diputar.
// Masukan: satu perintah per baris di stdin (toggle, play, pause, next, previous). stdin ditutup = berhenti.
#import <Foundation/Foundation.h>
#include <dlfcn.h>

typedef void (*GetInfoFn)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*GetClientFn)(dispatch_queue_t, void (^)(id));
typedef NSString *(*ClientBundleFn)(id);
typedef void (*GetPlayingFn)(dispatch_queue_t, void (^)(BOOL));
typedef void (*RegisterFn)(dispatch_queue_t);
typedef Boolean (*SendCommandFn)(int, NSDictionary *);

static GetInfoFn getInfo;
static GetClientFn getClient;
static ClientBundleFn clientBundle;
static GetPlayingFn getPlaying;
static SendCommandFn sendCommand;
static NSString *lastLine;

static id number(NSDictionary *info, NSString *key) {
    id value = info[[@"kMRMediaRemoteNowPlayingInfo" stringByAppendingString:key]];
    return [value isKindOfClass:NSNumber.class] ? value : @0;
}

static void emit(void) {
    dispatch_queue_t queue = dispatch_get_main_queue();
    getInfo(queue, ^(NSDictionary *info) {
        getPlaying(queue, ^(BOOL playing) {
            getClient(queue, ^(id client) {
                NSMutableDictionary *out = [NSMutableDictionary dictionary];
                NSString *title = info[@"kMRMediaRemoteNowPlayingInfoTitle"];
                if ([title isKindOfClass:NSString.class] && title.length > 0) {
                    out[@"title"] = title;
                    out[@"artist"] = info[@"kMRMediaRemoteNowPlayingInfoArtist"] ?: @"";
                    out[@"album"] = info[@"kMRMediaRemoteNowPlayingInfoAlbum"] ?: @"";
                    out[@"duration"] = number(info, @"Duration");
                    out[@"elapsed"] = number(info, @"ElapsedTime");
                    out[@"rate"] = number(info, @"PlaybackRate");
                    NSDate *stamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
                    out[@"timestamp"] = @([stamp isKindOfClass:NSDate.class] ? stamp.timeIntervalSince1970 : NSDate.date.timeIntervalSince1970);
                    out[@"playing"] = @(playing);
                    NSString *bundle = client && clientBundle ? clientBundle(client) : nil;
                    out[@"bundle"] = bundle ?: @"";
                }
                NSData *data = [NSJSONSerialization dataWithJSONObject:out options:NSJSONWritingSortedKeys error:nil];
                NSString *line = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                if ([line isEqualToString:lastLine]) return;
                lastLine = line;
                printf("%s\n", line.UTF8String);
                fflush(stdout);
            });
        });
    });
}

static void handleCommand(NSString *command) {
    NSDictionary *codes = @{@"play": @0, @"pause": @1, @"toggle": @2, @"next": @4, @"previous": @5};
    NSNumber *code = codes[command];
    if (code && sendCommand) sendCommand(code.intValue, nil);
}

// Dipanggil perl sebagai XSUB; argumennya (interpreter perl dan CV) tidak dipakai.
void lyricsbar_now_playing(void *perl, void *cv) {
    void *handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!handle) { printf("{\"error\":\"MediaRemote\"}\n"); fflush(stdout); exit(1); }
    getInfo = (GetInfoFn)dlsym(handle, "MRMediaRemoteGetNowPlayingInfo");
    getClient = (GetClientFn)dlsym(handle, "MRMediaRemoteGetNowPlayingClient");
    clientBundle = (ClientBundleFn)dlsym(handle, "MRNowPlayingClientGetBundleIdentifier");
    getPlaying = (GetPlayingFn)dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    sendCommand = (SendCommandFn)dlsym(handle, "MRMediaRemoteSendCommand");
    RegisterFn registerFn = (RegisterFn)dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications");
    if (registerFn) registerFn(dispatch_get_main_queue());

    for (NSString *name in @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification"]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *note) { emit(); }];
    }
    // Cadangan kalau notifikasi terlewat; hanya mencetak saat ada yang berubah.
    [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *timer) { emit(); }];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        char buffer[64];
        while (fgets(buffer, sizeof buffer, stdin)) {
            NSString *command = [[NSString stringWithUTF8String:buffer]
                                 stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            dispatch_async(dispatch_get_main_queue(), ^{ handleCommand(command); });
        }
        exit(0);
    });

    emit();
    [NSRunLoop.mainRunLoop run];
}
