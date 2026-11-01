#pragma once
#include <stdbool.h>

typedef enum { BDIntentNone = 0, BDIntentPause = 1, BDIntentTopUp = 2, BDIntentBattery = 3 } BDIntent;
typedef struct { int baseLimit; int batteryFloor; BDIntent intent; bool topUpComplete; } BDPolicy;
// 0 restores the user's settings; 100 temporarily allows full charging.
int bd_policy_target(BDPolicy *policy, int level, bool full, bool disconnectedForFiveSeconds);
bool bd_valid_base_limit(int limit);
bool bd_valid_battery_floor(int floor);
