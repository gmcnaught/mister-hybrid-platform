/* Cross-compile smoke test for spec/generated (CI builds it with mister-armhf-base). */
#define MISTER_PROFILE_GM_FABRIC
#include "mister_map_gm_fabric.h"
#include "mister_profiles.h"
#include <stdio.h>

#ifdef __cplusplus
static_assert(MISTER_MAP_ROLE_SCANOUT_COUNTER == 0x3BFB0018u, "gm-fabric scanout counter");
#else
_Static_assert(MISTER_MAP_ROLE_SCANOUT_COUNTER == 0x3BFB0018u, "gm-fabric scanout counter");
#endif

int main(void)
{
    for (int i = 0; i < MISTER_PROFILE_COUNT; i++)
        printf("%-16s joy_p1=0x%08x\n", mister_profiles[i].name,
               (unsigned)mister_profiles[i].role[MISTER_ROLE_JOY_P1]);
    return 0;
}
