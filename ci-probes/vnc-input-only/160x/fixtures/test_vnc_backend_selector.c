/* Execute the ACTUAL production selector; CPU-only, no device/SDK/hook APIs.
 * cc -std=c11 -Wall -Wextra -Iinclude misc/test_vnc_backend_selector.c -o test_vnc_backend_selector
 * ./test_vnc_backend_selector
 */
#include "macws_vnc_profile.h"
#include <assert.h>

int main(void) {
    bool nativeCG=true;
    assert(macws_vnc_select_frame_backend(NULL,&nativeCG) && !nativeCG);
    nativeCG=true;
    assert(macws_vnc_select_frame_backend("shared-mmap",&nativeCG) && !nativeCG);
    nativeCG=false;
    assert(macws_vnc_select_frame_backend("native-cg",&nativeCG) && nativeCG);
    const char *unknown[]={"","mmap","stock","0","1","Native-CG","native-cg ","shared_mmap"};
    for (unsigned i=0;i<sizeof(unknown)/sizeof(unknown[0]);i++) {
        nativeCG=true;
        assert(!macws_vnc_select_frame_backend(unknown[i],&nativeCG) && nativeCG);
        nativeCG=false;
        assert(!macws_vnc_select_frame_backend(unknown[i],&nativeCG) && !nativeCG);
    }
    assert(!macws_vnc_select_frame_backend(NULL,NULL));
    assert(!macws_vnc_select_frame_backend("native-cg",NULL));
    return 0;
}
