#include "BDPolicy.h"
bool bd_valid_base_limit(int limit) { return limit == 0 || (limit >= 50 && limit <= 100); }
bool bd_valid_battery_floor(int floor) { return floor >= 5 && floor <= 30 && floor % 5 == 0; }
int bd_policy_target(BDPolicy *policy, int level, bool full, bool disconnected) {
    if (disconnected) { policy->intent = BDIntentNone; policy->topUpComplete = false; }
    int floor = policy->intent == BDIntentBattery ? policy->batteryFloor : 20;
    if ((policy->intent == BDIntentPause || policy->intent == BDIntentBattery) && level <= floor) policy->intent = BDIntentNone;
    if (policy->intent == BDIntentPause || policy->intent == BDIntentBattery) return floor;
    if (policy->intent == BDIntentTopUp) {
        if (full || level >= 100) policy->topUpComplete = true;
        return 100;
    }
    return policy->baseLimit;
}
