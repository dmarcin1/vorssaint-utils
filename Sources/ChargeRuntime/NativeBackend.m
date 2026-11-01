// Native archive mechanism adapted from MIT Battery macOS 27 patch contributors
// and Ampere. See LICENSES/NativePolicy-MIT.txt and LICENSES/Ampere-MIT.txt.
#import "ChargeRuntime.h"
#import "native-policy.h"
#import <IOKit/IOKitLib.h>
#import <IOKit/ps/IOPowerSources.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <notify.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <libproc.h>
#include <fcntl.h>
#include <unistd.h>

@interface NSObject (BDPowerUI)
- (id)initWithClientName:(NSString *)name;
- (BOOL)isMCLSupported;
- (uint64_t)isMCLCurrentlyEnabled:(NSError **)error;
- (BOOL)enableMCL:(NSError **)error;
- (BOOL)disableMCL:(NSError **)error;
@end

static CFStringRef const PowerUIDomain = CFSTR("com.apple.smartcharging.topoffprotection");
static CFStringRef const PolicyDomain = CFSTR("com.apple.powerd.charging");
static BOOL fail(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"com.bodian.control" code:1
                                       userInfo:@{NSLocalizedDescriptionKey: message}];
    return NO;
}
BOOL BDProtectedDirectory(NSString *path, BOOL readable) {
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st)) {
        if (errno != ENOENT || mkdir(path.fileSystemRepresentation, readable ? 0755 : 0700)) return NO;
        if (lstat(path.fileSystemRepresentation, &st)) return NO;
    }
    return S_ISDIR(st.st_mode) && st.st_uid == 0 && (st.st_mode & 0022) == 0;
}
BOOL BDWritePlist(NSDictionary *value, NSString *path, mode_t mode) {
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:value
                            format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
    if (!data) return NO;
    NSString *temp = [path stringByAppendingFormat:@".%@", NSUUID.UUID.UUIDString];
    int fd = open(temp.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode);
    if (fd < 0) return NO;
    const uint8_t *bytes = data.bytes;
    size_t offset = 0;
    while (offset < data.length) {
        ssize_t n = write(fd, bytes + offset, data.length - offset);
        if (n <= 0) { close(fd); unlink(temp.fileSystemRepresentation); return NO; }
        offset += (size_t)n;
    }
    BOOL ok = fsync(fd) == 0;
    close(fd);
    if (ok) ok = rename(temp.fileSystemRepresentation, path.fileSystemRepresentation) == 0;
    if (!ok) unlink(temp.fileSystemRepresentation);
    return ok;
}
NSDictionary *BDReadProtectedPlist(NSString *path, NSUInteger maxBytes) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
    struct stat st;
    if (fd < 0) return nil;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_uid != 0 || (st.st_mode & 0022) ||
        st.st_size < 0 || (uint64_t)st.st_size > maxBytes || st.st_nlink != 1) { close(fd); return nil; }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)st.st_size];
    size_t offset = 0;
    while (offset < data.length) {
        ssize_t n = read(fd, (uint8_t *)data.mutableBytes + offset, data.length - offset);
        if (n <= 0) { close(fd); return nil; }
        offset += (size_t)n;
    }
    close(fd);
    id value = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL];
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}
NSString *BDCodeHash(NSString *path) {
    SecStaticCodeRef code = NULL;
    if (SecStaticCodeCreateWithPath((__bridge CFURLRef)[NSURL fileURLWithPath:path], kSecCSDefaultFlags, &code)) return nil;
    OSStatus status = SecStaticCodeCheckValidity(code, kSecCSStrictValidate, NULL);
    CFDictionaryRef raw = NULL;
    if (!status) status = SecCodeCopySigningInformation(code, kSecCSSigningInformation, &raw);
    CFRelease(code);
    if (status || !raw) return nil;
    NSDictionary *info = CFBridgingRelease(raw);
    NSData *hash = info[(__bridge NSString *)kSecCodeInfoUnique];
    if (![hash isKindOfClass:NSData.class] || hash.length != 20) return nil;
    NSMutableString *result = [NSMutableString new];
    for (NSUInteger i = 0; i < hash.length; i++) [result appendFormat:@"%02x", ((uint8_t *)hash.bytes)[i]];
    return result;
}
NSDictionary *BDReadBattery(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"));
    CFMutableDictionaryRef raw = NULL;
    if (!service) return @{};
    kern_return_t status = IORegistryEntryCreateCFProperties(service, &raw, kCFAllocatorDefault, 0);
    IOObjectRelease(service);
    if (status || !raw) return @{};
    NSDictionary *all = CFBridgingRelease(raw);
    NSMutableDictionary *values = [NSMutableDictionary new];
    for (NSString *key in @[@"CurrentCapacity", @"IsCharging", @"FullyCharged", @"ExternalConnected",
                            @"ExternalChargeCapable", @"UpdateTime", @"Amperage", @"InstantAmperage"])
        if ([all[key] isKindOfClass:NSNumber.class]) values[key] = all[key];
    for (NSString *key in @[@"Amperage", @"InstantAmperage"])
        if (values[key]) values[key] = @([values[key] longLongValue]);
    CFTypeRef info = IOPSCopyPowerSourcesInfo();
    if (info) {
        CFStringRef source = IOPSGetProvidingPowerSourceType(info);
        if (source) values[@"source"] = (__bridge NSString *)source;
        CFRelease(info);
    }
    return values;
}
NSString *BDBootSession(void) {
    char value[128] = {0}; size_t size = sizeof value;
    if (sysctlbyname("kern.bootsessionuuid", value, &size, NULL, 0) || size >= sizeof value) return nil;
    return @(value);
}
static NSDictionary *powerPreferences(void) {
    if (!CFPreferencesSynchronize(PolicyDomain, kCFPreferencesAnyUser, kCFPreferencesCurrentHost)) return nil;
    return CFBridgingRelease(CFPreferencesCopyMultiple(NULL, PolicyDomain, kCFPreferencesAnyUser, kCFPreferencesCurrentHost));
}
static NSDictionary *originalPreferences(void) {
    if (!CFPreferencesSynchronize(PowerUIDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)) return nil;
    NSMutableDictionary *values = [NSMutableDictionary new];
    for (NSString *key in @[@"MCLFeatureState", @"mclLimitValue"]) {
        id value = CFBridgingRelease(CFPreferencesCopyValue((__bridge CFStringRef)key, PowerUIDomain,
                                      kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
        if (value && ![value isKindOfClass:NSNumber.class]) return nil;
        if (value) values[key] = value;
    }
    return values;
}
static BOOL writePreferences(NSDictionary *values) {
    for (NSString *key in @[@"MCLFeatureState", @"mclLimitValue"])
        CFPreferencesSetValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)values[key], PowerUIDomain,
                             kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    return CFPreferencesSynchronize(PowerUIDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        && notify_post("com.apple.smartcharging.defaultschanged") == NOTIFY_STATUS_OK;
}
static id powerClient(void) {
    static void *framework;
    if (!framework) framework = dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/Versions/A/PowerUI", RTLD_NOW);
    Class cls = framework ? NSClassFromString(@"PowerUISmartChargeClient") : nil;
    NSDictionary *types = @{@"initWithClientName:":@"@", @"isMCLSupported":@"B",
        @"isMCLCurrentlyEnabled:":@"Q", @"enableMCL:":@"B", @"disableMCL:":@"B"};
    for (NSString *name in types) {
        Method method = class_getInstanceMethod(cls, NSSelectorFromString(name));
        if (!method) return nil;
        char *type = method_copyReturnType(method);
        BOOL ok = [types[name] isEqualToString:@(type)];
        free(type);
        if (!ok) return nil;
    }
    id client = [[cls alloc] initWithClientName:@"com.vorssaint.utils"];
    return [client isMCLSupported] ? client : nil;
}
static BOOL disableManual(id client, NSError **error) {
    NSError *underlying = nil;
    uint64_t enabled = [client isMCLCurrentlyEnabled:&underlying];
    if (underlying) return fail(error, underlying.localizedDescription);
    if (enabled == 0 && ![client enableMCL:&underlying]) return fail(error, underlying.localizedDescription ?: @"无法准备系统充电设置。");
    if (![client disableMCL:&underlying]) return fail(error, underlying.localizedDescription ?: @"无法解除系统充电上限。");
    return YES;
}
static NSString *registeredOutput(void) {
    NSTask *task = [NSTask new]; task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/pmset"];
    task.arguments = @[@"-g", @"battlimit"];
    NSPipe *pipe = NSPipe.pipe; task.standardOutput = pipe; task.standardError = NSFileHandle.fileHandleWithNullDevice;
    if (![task launchAndReturnError:NULL]) return nil;
    double deadline = NSDate.date.timeIntervalSince1970 + 5;
    while (task.running && NSDate.date.timeIntervalSince1970 < deadline) usleep(50000);
    if (task.running) { kill(task.processIdentifier, SIGKILL); [task waitUntilExit]; return nil; }
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile]; [task waitUntilExit];
    if (task.terminationStatus || data.length > 65536) return nil;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}
static pid_t powerPID(void) {
    pid_t pids[8192]; int bytes = proc_listpids(PROC_ALL_PIDS, 0, pids, sizeof pids);
    if (bytes <= 0 || (size_t)bytes >= sizeof pids) return -1;
    pid_t found = -1;
    for (size_t i = 0; i < (size_t)bytes / sizeof(pid_t); i++) {
        char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
        if (pids[i] > 1 && proc_pidpath(pids[i], path, sizeof path) > 0 &&
            !strcmp(path, "/System/Library/CoreServices/powerd.bundle/powerd")) {
            if (found > 1) return -1; found = pids[i];
        }
    }
    return found;
}
static BOOL reloadPower(NSError **error) {
    pid_t old = powerPID();
    if (old < 2 || kill(old, SIGHUP)) return fail(error, @"无法重载系统电源服务；恢复记录已保留。");
    for (int i = 0; i < 100; i++) { usleep(100000); pid_t next = powerPID(); if (next > 1 && next != old) return YES; }
    return fail(error, @"系统电源服务未及时恢复，请重试恢复系统管理。");
}

@implementation BDNativeBackend {
    NSString *_directory, *_journalPath;
    NSMutableDictionary *_journal;
    id _client;
    NSInteger _target;
    NSTimeInterval _actionTime;
    BOOL _registrationConfirmed, _usingBattery;
}
- (instancetype)initWithStateDirectory:(NSString *)directory {
    if ((self = [super init])) {
        _directory = directory; _journalPath = [directory stringByAppendingPathComponent:@"recovery.plist"];
    }
    return self;
}
- (NSInteger)target { return _target; }
- (BOOL)usingBattery { return _usingBattery; }
- (NSTimeInterval)actionTime { return _actionTime; }
- (BOOL)registrationConfirmed { return _registrationConfirmed; }
- (BOOL)save:(NSError **)error {
    return BDWritePlist(_journal, _journalPath, 0600) || fail(error, @"无法保存恢复记录，未继续操作。");
}
- (BOOL)recover:(NSError **)error {
    if (!BDProtectedDirectory(_directory, YES)) return fail(error, @"后台数据目录权限不安全。");
    if (![NSFileManager.defaultManager fileExistsAtPath:_journalPath]) return YES;
    NSDictionary *saved = BDReadProtectedPlist(_journalPath, 65536);
    if (![saved[@"schema"] isEqual:@1] || ![saved[@"original"] isKindOfClass:NSDictionary.class] ||
        ![saved[@"boot"] isKindOfClass:NSString.class] || ![saved[@"token"] isKindOfClass:NSData.class] ||
        [saved[@"token"] length] != 16 || ![saved[@"owner"] isKindOfClass:NSNumber.class])
        return fail(error, @"恢复记录无效，已停止自动控制。");
    for (NSString *key in saved[@"original"])
        if (![@[@"MCLFeatureState", @"mclLimitValue"] containsObject:key] ||
            ![saved[@"original"][key] isKindOfClass:NSNumber.class]) return fail(error, @"原设置记录无效。");
    _journal = saved.mutableCopy;
    return [self restore:error];
}
- (BOOL)prepare:(NSError **)error {
    if (!_client) _client = powerClient();
    if (!_client) return fail(error, @"当前系统的原生充电接口不可用或已变化。");
    if (_journal) return YES;
    NSDictionary *original = originalPreferences(); NSString *boot = BDBootSession();
    if (!original || !boot) return fail(error, @"无法读取原设置，未修改充电策略。");
    uuid_t bytes; [NSUUID.UUID getUUIDBytes:bytes];
    _journal = [@{@"schema":@1, @"original":original, @"boot":boot,
                 @"token":[NSData dataWithBytes:bytes length:16], @"owner":@(getpid())} mutableCopy];
    if (![self save:error]) { _journal = nil; return NO; }
    return YES;
}
- (BOOL)replace:(NSData *)original with:(NSData *)updated error:(NSError **)error {
    NSDictionary *current = powerPreferences();
    if (![current[@"bootSessionUUID"] isEqual:_journal[@"boot"]] || ![current[@"policies"] isEqual:original])
        return fail(error, @"系统策略被同时修改，已停止写入。请重试。");
    CFPreferencesSetValue(CFSTR("policies"), (__bridge CFDataRef)updated, PolicyDomain,
                         kCFPreferencesAnyUser, kCFPreferencesCurrentHost);
    if (!CFPreferencesSynchronize(PolicyDomain, kCFPreferencesAnyUser, kCFPreferencesCurrentHost) ||
        ![powerPreferences()[@"policies"] isEqual:updated]) return fail(error, @"原生策略写入未确认。");
    return reloadPower(error);
}
- (BOOL)removeOwned:(NSError **)error {
    if (!_journal || ![_journal[@"boot"] isEqual:BDBootSession()]) return YES;
    NSDictionary *prefs = powerPreferences(); NSArray *records = nil;
    if (![prefs[@"bootSessionUUID"] isEqual:_journal[@"boot"]] || !b27_readPolicyArchive(prefs[@"policies"], &records))
        return fail(error, @"原生策略格式不可确认，恢复记录已保留。");
    for (NSDictionary *record in records)
        if ([record[@"token"] isEqual:_journal[@"token"]] &&
            ![record[@"object"][@"owner"] isEqual:_journal[@"owner"]])
            return fail(error, @"策略所有者发生变化，未移除其他进程的策略。");
    NSData *updated = b27_ownedPolicyData(prefs[@"policies"], _journal[@"token"], 0, 0, NO, YES);
    if (!updated) return fail(error, @"无法安全移除自有策略。");
    if (![updated isEqual:prefs[@"policies"]] && ![self replace:prefs[@"policies"] with:updated error:error]) return NO;
    NSArray *live = b27_registeredPolicies(registeredOutput());
    if (!live) return fail(error, @"无法核验策略是否已移除。");
    for (NSDictionary *row in live)
        if ([row[@"chargeSocLimitReason"] isEqual:B27PolicyReason]) return fail(error, @"自有策略仍在生效。");
    return YES;
}
- (BOOL)restore:(NSError **)error {
    if (!_journal && [NSFileManager.defaultManager fileExistsAtPath:_journalPath])
        return fail(error, @"恢复记录无法解析；未覆盖记录或宣告已恢复。");
    if (!_journal) { _target = 0; _usingBattery = NO; _registrationConfirmed = YES; return YES; }
    if (!_client) _client = powerClient();
    if (!_client || ![self removeOwned:error]) return NO;
    if (!disableManual(_client, error) || !writePreferences(_journal[@"original"]) ||
        ![originalPreferences() isEqual:_journal[@"original"]])
        return fail(error, @"恢复原设置尚未确认，记录已保留。");
    if (unlink(_journalPath.fileSystemRepresentation)) return fail(error, @"已恢复设置，但无法清理恢复记录。");
    _journal = nil; _target = 0; _usingBattery = NO; _actionTime = NSDate.date.timeIntervalSince1970; _registrationConfirmed = YES;
    return YES;
}
- (BOOL)applyTarget:(NSInteger)target usingBattery:(BOOL)usingBattery error:(NSError **)error {
    if (target == 0) return [self restore:error];
    if (usingBattery ? !bd_valid_battery_floor((int)target) : !(target == 20 || (target >= 50 && target <= 100))) return fail(error, @"无效充电目标。");
    if (_target == target && _usingBattery == usingBattery && _registrationConfirmed) return YES;
    if (![self prepare:error]) return NO;
    if (!disableManual(_client, error) || !writePreferences(@{@"MCLFeatureState":@0, @"mclLimitValue":@100}))
        return fail(error, @"无法取得原生充电策略控制权。");
    if (target == 100) {
        if (![self removeOwned:error]) return NO;
    } else {
        NSDictionary *prefs = powerPreferences();
        if (![prefs[@"bootSessionUUID"] isEqual:BDBootSession()] || !b27_readPolicyArchive(prefs[@"policies"], NULL))
            return fail(error, @"当前系统策略 archive 尚不可用，未写入。");
        NSData *updated = b27_ownedPolicyData(prefs[@"policies"], _journal[@"token"], getpid(), (int)target, usingBattery, NO);
        if (!updated) return fail(error, @"系统策略结构变化或自有 token 冲突。");
        if (![updated isEqual:prefs[@"policies"]] && ![self replace:prefs[@"policies"] with:updated error:error]) return NO;
    }
    _target = target; _usingBattery = usingBattery; _actionTime = NSDate.date.timeIntervalSince1970; _registrationConfirmed = NO;
    return [self checkRegistration:error];
}
- (BOOL)checkRegistration:(NSError **)error {
    if (_target == 0) { _registrationConfirmed = !_journal; return _registrationConfirmed; }
    if (_target == 100) {
        NSArray *rows = b27_registeredPolicies(registeredOutput());
        _registrationConfirmed = rows != nil && rows.count == 0;
    } else {
        for (int i = 0; i < 10; i++) {
            _registrationConfirmed = b27_ownedRegistered(registeredOutput(), (int)_target, getpid(), _usingBattery);
            if (_registrationConfirmed) break;
            usleep(200000);
        }
    }
    return _registrationConfirmed || fail(error, @"原生策略尚未确认。请恢复系统管理后重试。");
}
@end
