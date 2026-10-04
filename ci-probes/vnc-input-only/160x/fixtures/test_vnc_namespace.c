/* Generated from actual production typedefs by prepare_vnc_adapter.py.
 * Portable CPU/namespace check, no Objective-C runtime/Mach/hook execution.
 * cc -std=c11 -Wall -Wextra -Iinclude misc/test_vnc_namespace.c -o test_vnc_namespace
 * ./test_vnc_namespace
 */
#include "macws_vnc_profile.h"
#include <assert.h>
#include <limits.h>
/* Compile-only stand-ins for SDK types in the copied function declarations. */
typedef void *id;
typedef void *SEL;
typedef signed char BOOL;
typedef struct { double x,y; } CGPoint;
typedef struct { double width,height; } CGSize;
typedef struct { CGPoint origin; CGSize size; } CGRect;
#if defined(MACWS_VNC_TEST_NAMESPACE_COLLISION)
/* Negative build control: recreate the previous enum/typedef name collision.
 * Compiling with this define must fail at the copied ReadExact typedef. */
enum { MacWSVNCReadExact = 5 };
#endif
typedef void (*MacWSVNCHandleMouse)(id, SEL, int, CGPoint, void *);
typedef void (*MacWSVNCRFBStartup)(id, SEL, void *);
typedef int32_t (*MacWSVNCPostLegacyMouseEvent)(CGPoint, int32_t, uint32_t,
                                                int32_t, ...);
typedef void (*MacWSVNCHandleKeyboard)(id, SEL, int, uint64_t, void *);
typedef void (*MacWSVNCSendKeyEvent)(id, SEL, unsigned short, BOOL, uint64_t);
typedef void (*MacWSVNCSetKeyModifiers)(id, SEL, uint64_t);
typedef uint32_t (*MacWSVNCMainDisplayID)(void);
typedef CGRect (*MacWSVNCDisplayBounds)(uint32_t);
typedef void (*MacWSVNCRefreshCallback)(uint32_t, const CGRect *, void *);
typedef int (*MacWSRFBSendFramebufferUpdate)(void *, MacWSVNCRegion);
typedef int (*MacWSVNCReadExact)(void *, void *, size_t);
typedef void (*MacWSVNCProcessNormalMessage)(void *);
_Static_assert(MacWSVNCSymbolCount == 7, "all public symbols counted");
_Static_assert(MacWSVNCSymbolReadExact == 5, "ReadExact index preserved");
static int read_large(void *client,void *buffer,size_t length) {
    assert(client==(void *)(uintptr_t)0x1234 && buffer==NULL);
    return length > UINT32_MAX ? 42 : 11;
}
int main(void) {
    _Static_assert(sizeof(size_t)==8, "reviewed LP64 ReadExact ABI");
    MacWSVNCReadExact reader=read_large;
    assert(reader((void *)(uintptr_t)0x1234,NULL,(size_t)UINT64_C(0x1000000d0))==42);
    return 0;
}
