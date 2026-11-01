#import <Foundation/Foundation.h>
#import "ChargeShared.h"
NS_ASSUME_NONNULL_BEGIN
@interface BDNativeBackend : NSObject
@property (readonly) NSInteger target;
@property (readonly) BOOL usingBattery;
@property (readonly) NSTimeInterval actionTime;
@property (readonly) BOOL registrationConfirmed;
- (instancetype)initWithStateDirectory:(NSString *)directory;
- (BOOL)recover:(NSError **)error;
- (BOOL)applyTarget:(NSInteger)target usingBattery:(BOOL)usingBattery error:(NSError **)error;
- (BOOL)restore:(NSError **)error;
- (BOOL)checkRegistration:(NSError **)error;
@end
NSDictionary *BDReadBattery(void);
BOOL BDProtectedDirectory(NSString *path, BOOL readable);
BOOL BDWritePlist(NSDictionary *value, NSString *path, mode_t mode);
NSDictionary * _Nullable BDReadProtectedPlist(NSString *path, NSUInteger maxBytes);
NSString * _Nullable BDCodeHash(NSString *path);
NS_ASSUME_NONNULL_END

NSString * _Nullable BDBootSession(void);
