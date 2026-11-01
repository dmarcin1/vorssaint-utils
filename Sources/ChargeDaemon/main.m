#import "ChargeRuntime.h"
#import <SystemConfiguration/SystemConfiguration.h>
#import <IOKit/ps/IOPowerSources.h>
#include <sys/stat.h>
#include <stdatomic.h>
#include <signal.h>
#include <unistd.h>
#include <sys/file.h>
#include <fcntl.h>

static NSString *const Directory = @"/Library/Application Support/Vorssaint/Charging";
static NSString *const AppPath = @"/Applications/Vorssaint.app";
static NSString *const ServiceName = @"com.vorssaint.utils.charge";
static uid_t consoleUser(void) {
    uid_t uid = 0; gid_t gid = 0;
    CFStringRef name = SCDynamicStoreCopyConsoleUser(NULL, &uid, &gid);
    if (name) CFRelease(name);
    return uid;
}
static NSString *requirement(NSString *identifier, NSString *hash) {
    return [NSString stringWithFormat:@"identifier \"%@\" and cdhash H\"%@\"", identifier, hash];
}
static BOOL prepareTrust(void) {
    struct stat st;
    if (lstat(AppPath.fileSystemRepresentation, &st) || !S_ISDIR(st.st_mode) || st.st_uid != 0 || (st.st_mode & 0022)) return NO;
    if (!BDProtectedDirectory(@"/Library/Application Support/Vorssaint", YES) || !BDProtectedDirectory(Directory, YES)) return NO;
    uid_t uid = consoleUser(); if (uid < 500) return NO;
    NSString *appHash = BDCodeHash(AppPath);
    NSString *helperHash = BDCodeHash([AppPath stringByAppendingPathComponent:@"Contents/MacOS/VorssaintChargeHelper"]);
    if (!appHash || !helperHash) return NO;
    return BDWritePlist(@{@"schema":@1, @"ownerUID":@(uid), @"appHash":appHash, @"helperHash":helperHash},
                        [Directory stringByAppendingPathComponent:@"trust.plist"], 0644);
}

@interface BDService : NSObject <BDChargeService, NSXPCListenerDelegate>
- (instancetype)initWithTrust:(NSDictionary *)trust;
- (void)start;
@end

@implementation BDService {
    NSDictionary *_trust;
    BDNativeBackend *_backend;
    BDPolicy _policy;
    dispatch_queue_t _queue;
    dispatch_source_t _timer, _watchdog, _terminate;
    CFRunLoopSourceRef _powerSource;
    NSString *_lastError, *_notice;
    BOOL _faulted, _unplugScheduled;
    NSTimeInterval _disconnectedAt, _lastRegistrationCheck;
    atomic_long _deadline;
}
- (instancetype)initWithTrust:(NSDictionary *)trust {
    if ((self = [super init])) {
        _trust = trust; _queue = dispatch_queue_create("com.bodian.control", DISPATCH_QUEUE_SERIAL);
        _backend = [[BDNativeBackend alloc] initWithStateDirectory:Directory];
        _policy = (BDPolicy){.baseLimit = 0, .batteryFloor = 20, .intent = BDIntentNone};
        atomic_init(&_deadline, 0);
    }
    return self;
}
static void powerChanged(void *context) {
    BDService *service = (__bridge BDService *)context;
    [service refreshAsync];
}
- (void)refreshAsync { dispatch_async(_queue, ^{ [self boundedRefresh]; }); }
- (void)boundedRefresh {
    atomic_store(&_deadline, (long)time(NULL) + 45);
    [self refresh]; atomic_store(&_deadline, 0);
}
- (void)start {
    _watchdog = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(_watchdog, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), 5 * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(_watchdog, ^{
        long deadline = atomic_load(&self->_deadline);
        if (deadline && time(NULL) > deadline) { NSLog(@"Control timed out; journal retained for launchd recovery."); kill(getpid(), SIGKILL); }
    });
    dispatch_resume(_watchdog);
    dispatch_sync(_queue, ^{
        atomic_store(&self->_deadline, (long)time(NULL) + 45);
        NSError *error = nil;
        if (![self->_backend recover:&error]) { self->_faulted = YES; self->_lastError = error.localizedDescription; }
        NSDictionary *saved = BDReadProtectedPlist([Directory stringByAppendingPathComponent:@"settings.plist"], 4096);
        NSNumber *limit = saved[@"baseLimit"];
        if ([NSFileManager.defaultManager fileExistsAtPath:[Directory stringByAppendingPathComponent:@"settings.plist"]] &&
            (![limit isKindOfClass:NSNumber.class] || !bd_valid_base_limit(limit.intValue))) {
            self->_faulted = YES; self->_lastError = @"基础策略记录无效，请恢复系统管理。";
        } else if (limit) self->_policy.baseLimit = limit.intValue;
        NSNumber *floor = saved[@"batteryFloor"];
        if (floor && (![floor isKindOfClass:NSNumber.class] || !bd_valid_battery_floor(floor.intValue))) {
            self->_faulted = YES; self->_lastError = @"使用电池阈值无效，请恢复系统管理。";
        } else if (floor) self->_policy.batteryFloor = floor.intValue;
        if (!self->_faulted) [self refresh];
        atomic_store(&self->_deadline, 0);
    });
    _powerSource = IOPSNotificationCreateRunLoopSource(powerChanged, (__bridge void *)self);
    if (_powerSource) CFRunLoopAddSource(CFRunLoopGetMain(), _powerSource, kCFRunLoopCommonModes);
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), 30 * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(_timer, ^{ [self boundedRefresh]; }); dispatch_resume(_timer);
    signal(SIGTERM, SIG_IGN);
    _terminate = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, _queue);
    dispatch_source_set_event_handler(_terminate, ^{
        atomic_store(&self->_deadline, (long)time(NULL) + 40);
        NSError *error = nil;
        BOOL restored = [self->_backend restore:&error];
        if (!restored) NSLog(@"Shutdown restore incomplete: %@", error.localizedDescription);
        exit(restored ? 0 : 1);
    }); dispatch_resume(_terminate);
}
- (BOOL)saveSettings {
    return BDWritePlist(@{@"baseLimit":@(_policy.baseLimit), @"batteryFloor":@(_policy.batteryFloor)}, [Directory stringByAppendingPathComponent:@"settings.plist"], 0600);
}
- (void)failControl:(NSError *)error {
    _faulted = YES; _lastError = error.localizedDescription ?: @"无法确认控制结果。";
    NSError *restoreError = nil;
    if (![_backend restore:&restoreError]) _lastError = [_lastError stringByAppendingFormat:@" 恢复未完成：%@", restoreError.localizedDescription];
}
- (void)refresh {
    if (_faulted) return;
    NSError *error = nil;
    if (consoleUser() != [_trust[@"ownerUID"] unsignedIntValue]) {
        if (![_backend restore:&error]) [self failControl:error];
        _policy.intent = BDIntentNone; _notice = @"控制用户已退出，已归还系统管理。"; return;
    }
    NSDictionary *battery = BDReadBattery();
    NSTimeInterval age = NSDate.date.timeIntervalSince1970 - [battery[@"UpdateTime"] doubleValue];
    if (!battery[@"CurrentCapacity"] || !battery[@"ExternalConnected"] || !battery[@"UpdateTime"] || age < -5 || age > 120) {
        [self failControl:[NSError errorWithDomain:@"com.bodian.sensor" code:1 userInfo:@{NSLocalizedDescriptionKey:@"电池数据缺失或过期，已停止控制。"}]]; return;
    }
    BOOL connected = [battery[@"ExternalConnected"] boolValue];
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (!connected && !_disconnectedAt) {
        _disconnectedAt = now;
        if (!_unplugScheduled) {
            _unplugScheduled = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), _queue, ^{
                self->_unplugScheduled = NO; [self boundedRefresh];
            });
        }
    }
    if (connected) _disconnectedAt = 0;
    BDIntent previous = _policy.intent;
    int target = bd_policy_target(&_policy, [battery[@"CurrentCapacity"] intValue],
                                  [battery[@"FullyCharged"] boolValue], _disconnectedAt && now - _disconnectedAt >= 5);
    if ((previous == BDIntentPause || previous == BDIntentBattery) && _policy.intent == BDIntentNone)
        _notice = connected ? @"低电量保护已结束临时模式。" : @"已拔线，临时操作已结束。";
    if (![_backend applyTarget:target usingBattery:(_policy.intent == BDIntentBattery) error:&error]) { [self failControl:error]; return; }
    if (now - _lastRegistrationCheck >= 60) {
        _lastRegistrationCheck = now;
        if (![_backend checkRegistration:&error]) [self failControl:error];
    }
}
- (NSDictionary *)status {
    NSDictionary *battery = BDReadBattery();
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    BOOL fresh = battery[@"UpdateTime"] && now - [battery[@"UpdateTime"] doubleValue] <= 120;
    NSString *verification = @"applying";
    if (_faulted) verification = @"failed";
    else if (!fresh) verification = @"unknown";
    else if (_backend.target == 0) verification = @"system";
    else if (_backend.registrationConfirmed && [battery[@"UpdateTime"] doubleValue] >= _backend.actionTime) {
        BOOL charging = [battery[@"IsCharging"] boolValue];
        long long current = [battery[@"Amperage"] longLongValue];
        int level = [battery[@"CurrentCapacity"] intValue];
        BOOL expectedHold = _backend.target < 100 && level >= _backend.target;
        if ((_backend.usingBattery && !charging && current < 0) ||
            (!_backend.usingBattery && expectedHold && !charging && current == 0) ||
            (!expectedHold && (charging || [battery[@"FullyCharged"] boolValue] || level >= 100))) verification = @"verified";
        else verification = now - _backend.actionTime > 150 ? @"unknown" : @"applying";
    }
    return @{@"version":@3, @"battery":battery, @"baseLimit":@(_policy.baseLimit),
        @"batteryFloor":@(_policy.batteryFloor), @"intent":@(_policy.intent), @"topUpComplete":@(_policy.topUpComplete),
        @"activeTarget":@(_backend.target), @"registered":@(_backend.registrationConfirmed),
        @"verification":verification, @"error":_lastError ?: @"", @"notice":_notice ?: @""};
}
- (void)perform:(BDCommand)command limit:(NSInteger)limit reply:(void (^)(NSData *, NSString *))reply {
    NSXPCConnection *connection = NSXPCConnection.currentConnection;
    uid_t uid = connection.effectiveUserIdentifier;
    dispatch_async(_queue, ^{
        if (uid != [self->_trust[@"ownerUID"] unsignedIntValue] || consoleUser() != uid) {
            reply(nil, @"仅安装所有者的当前登录会话可以控制充电。"); return;
        }
        if (command < BDCommandStatus || command > BDCommandSetBatteryFloor ||
            (command == BDCommandSetLimit && (limit < 0 || limit > 100 || !bd_valid_base_limit((int)limit))) ||
            (command == BDCommandSetBatteryFloor && (limit < 5 || limit > 30 || !bd_valid_battery_floor((int)limit)))) {
            reply(nil, @"无效控制请求。"); return;
        }
        atomic_store(&self->_deadline, (long)time(NULL) + 45);
        if (command == BDCommandStatus) {
            [self refresh];
        } else if (self->_faulted && command != BDCommandRestore) {
            atomic_store(&self->_deadline, 0); reply(nil, @"请先恢复系统管理，再尝试新的控制操作。"); return;
        } else {
            NSDictionary *battery = BDReadBattery();
            if ((command == BDCommandPause || command == BDCommandTopUp || command == BDCommandUseBattery) &&
                (![battery[@"ExternalConnected"] boolValue] || ![battery[@"ExternalChargeCapable"] boolValue] ||
                 ((command == BDCommandPause || command == BDCommandUseBattery) && [battery[@"CurrentCapacity"] intValue] <= (command == BDCommandUseBattery ? self->_policy.batteryFloor : 20)))) {
                atomic_store(&self->_deadline, 0); reply(nil, @"请连接外部电源，且当前电量须高于此模式的低电量阈值。"); return;
            }
            self->_notice = nil;
            if (command == BDCommandRestore) {
                NSError *error = nil;
                if ([self->_backend restore:&error]) {
                    self->_policy = (BDPolicy){.baseLimit=0,.batteryFloor=self->_policy.batteryFloor,.intent=BDIntentNone}; self->_faulted = NO; self->_lastError = nil;
                } else [self failControl:error];
            } else {
                if (command == BDCommandSetBatteryFloor) self->_policy.batteryFloor=(int)limit;
                if (command == BDCommandPause) self->_policy.intent = BDIntentPause;
                if (command == BDCommandUseBattery) { self->_policy.intent = BDIntentBattery; self->_policy.topUpComplete = NO; }
                if (command == BDCommandResume) { self->_policy.intent = BDIntentNone; self->_policy.topUpComplete = NO; }
                if (command == BDCommandTopUp) { self->_policy.intent = BDIntentTopUp; self->_policy.topUpComplete = NO; }
                if (command == BDCommandSetLimit) { self->_policy.baseLimit=(int)limit; self->_policy.intent=BDIntentNone; self->_policy.topUpComplete=NO; }
                [self refresh];
            }
            if (!self->_faulted && ![self saveSettings]) {
                [self failControl:[NSError errorWithDomain:@"com.bodian.storage" code:1 userInfo:@{NSLocalizedDescriptionKey:@"无法保存基础策略，已停止控制。"}]];
            }
        }
        NSData *data = [NSJSONSerialization dataWithJSONObject:[self status] options:NSJSONWritingSortedKeys error:NULL];
        atomic_store(&self->_deadline, 0);
        reply(data, nil);
    });
}
- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)connection {
    if (connection.effectiveUserIdentifier != [_trust[@"ownerUID"] unsignedIntValue]) return NO;
    connection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(BDChargeService)];
    connection.exportedObject = self; [connection resume]; return YES;
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27) return 78;
        if (geteuid() != 0) return 77;
        if (argc == 2 && !strcmp(argv[1], "--prepare-trust")) return prepareTrust() ? 0 : 1;
        if (!BDProtectedDirectory(Directory, YES)) return 78;
        int lock = open([Directory stringByAppendingPathComponent:@"service.lock"].fileSystemRepresentation,
                        O_CREAT | O_RDWR | O_NOFOLLOW, 0600);
        struct stat lockInfo;
        if (lock < 0 || fstat(lock, &lockInfo) || !S_ISREG(lockInfo.st_mode) || lockInfo.st_uid != 0 ||
            (lockInfo.st_mode & 0077) || lockInfo.st_nlink != 1 || flock(lock, LOCK_EX | LOCK_NB)) return 79;
        NSDictionary *trust = BDReadProtectedPlist([Directory stringByAppendingPathComponent:@"trust.plist"], 4096);
        NSString *helper = [AppPath stringByAppendingPathComponent:@"Contents/MacOS/VorssaintChargeHelper"];
        if (![trust[@"schema"] isEqual:@1] || [trust[@"ownerUID"] unsignedIntValue] < 500 ||
            ![BDCodeHash(helper) isEqual:trust[@"helperHash"]] || ![BDCodeHash(AppPath) isEqual:trust[@"appHash"]]) return 78;
        BDService *service = [[BDService alloc] initWithTrust:trust]; [service start];
        NSXPCListener *listener = [[NSXPCListener alloc] initWithMachServiceName:ServiceName];
        [listener setConnectionCodeSigningRequirement:requirement(@"com.vorssaint.utils", trust[@"appHash"])];
        listener.delegate = service; [listener resume]; CFRunLoopRun();
    }
    return 0;
}
