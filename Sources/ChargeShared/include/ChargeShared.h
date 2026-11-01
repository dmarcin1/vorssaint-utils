#import <Foundation/Foundation.h>
#import "BDPolicy.h"
NS_ASSUME_NONNULL_BEGIN
typedef NS_ENUM(NSInteger, BDCommand) {
    BDCommandStatus = 0, BDCommandPause = 1, BDCommandResume = 2,
    BDCommandSetLimit = 3, BDCommandTopUp = 4, BDCommandRestore = 5, BDCommandUseBattery = 6, BDCommandSetBatteryFloor = 7
};
@protocol BDChargeService
- (void)perform:(BDCommand)command limit:(NSInteger)limit
          reply:(void (^)(NSData * _Nullable data, NSString * _Nullable error))reply NS_SWIFT_NAME(perform(_:limit:reply:));
@end
NS_ASSUME_NONNULL_END
