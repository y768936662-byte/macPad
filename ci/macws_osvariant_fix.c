// macws_osvariant_fix.c — minimal DYLD_INSERT_LIBRARIES shim.
//
// PURPOSE: bypass the brk-1 trap in libSystem_initializer WITHOUT waiting on
// the upstream author and WITHOUT touching the kernel / AMFI / dyld-platform
// checks. User-space only, reversible, tiny blast radius.
//
// WHY THIS WORKS (the "wall2 is not a kernel wall" finding):
//   chrooted macOS binary loads -> libSystem_initializer (libSystem.B.dylib)
//     -> os_variant_has_internal_diagnostics (libsystem_darwin.dylib, an
//        exported symbol, cross-library call so __interpose REACHES it)
//       -> _check_internal_content -> brk 1 when the os_variant word read from
//          kern.osvariant_status does not advertise internal diagnostics.
//   On iPadOS 16.5.1 the real kern.osvariant_status word has that bit unset,
//   so the assert trips. The procursus build (libmachook CDHash 026b63cb)
//   already interposes the SAME surface and keeps the process alive
//   (CHROOT_BASH_OK) — proving a user-space interpose IS sufficient.
//
// The GitHub-CI libmachook dies only because its link form (chained fixups +
// iOS platform2 + PAC pointers) fails to register the __interpose table on
// the target dyld. This shim is deliberately TRIVIAL: pure C, no ObjC /
// Metal / AppKit / GPU, so its constructors are clean and dyld always loads
// it and registers its __interpose table before any target's libSystem
// initializers run.
//
// The os_variant_* return values and the osvariant_status word are the exact
// values mac_hooks.m:11362-11383 / os_variant_hooks.x already use and that
// are proven alive — we do not invent new ones.
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <sys/param.h>
#include <sys/sysctl.h>

// Self-contained DYLD_INTERPOSE (mirrors interpose.h) so the shim builds
// standalone with plain clang / Xcode ld64, no project headers needed.
#define DYLD_INTERPOSE(_replacement,_replacee) \
   __attribute__((used)) static struct{ const void* replacement; const void* replacee; } _interpose_##_replacee \
            __attribute__ ((section ("__DATA,__interpose"))) = { (const void*)(unsigned long)&_replacement, (const void*)(unsigned long)&_replacee };

// Original libsystem decls. sysctl(3)/sysctlbyname(3) come from the SDK's
// <sys/sysctl.h> — do NOT redeclare them locally (signatures differ across
// SDKs, e.g. 14.5 uses `size_t *` for the namelen parameter; declaring
// `unsigned int *` collides and the compiler reports
// "conflicting types for 'sysctlnametomib'" even though the object link would
// be fine).
extern int sysctl(int *name, unsigned int namelen, void *oldp, size_t *oldlenp,
                  void *newp, size_t newlen);
extern int sysctlbyname(const char *name, void *oldp, size_t *oldlenp,
                        void *newp, size_t newlen);

// os_variant family (exported by libsystem_darwin; values per os_variant_hooks.x)
bool os_variant_is_basesystem(const char *subsystem);
bool os_variant_is_recovery(const char *subsystem);
bool os_variant_allows_internal_security_policies(const char *subsystem);
bool os_variant_has_internal_content(const char *subsystem);
bool os_variant_has_internal_ui(const char *subsystem);
bool os_variant_has_internal_diagnostics(const char *subsystem);

// Verified-alive value (mac_hooks.m:11366): bit0 = diagnostics enabled.
#define MACWS_OSVARIANT_STATUS_ALIVE 0x70010000f388828bULL

// sysctlnametomib converts a name to a MIB; its 14.5 SDK signature uses
// `size_t *` for the namelen argument.
extern int sysctlnametomib(const char *name, int *name_mib, size_t *namelen);

// Call the real sysctl(2) via the lower-level sysctl(3) so we never recurse
// into our own sysctlbyname interpose (same pattern as macws_real_sysctlbyname
// in mac_hooks.m). The sysctl() symbol is a plain syscall wrapper, not part
// of the interpose set.
static int macws_real_sysctlbyname(const char *name, void *oldp, size_t *oldlenp,
                                   void *newp, size_t newlen) {
    int mib[CTL_MAXNAME];
    size_t miblen = CTL_MAXNAME;
    if (!name) { errno = EINVAL; return -1; }
    if (sysctlnametomib(name, mib, &miblen) != 0) return -1;
    return sysctl(mib, (unsigned int)miblen, oldp, oldlenp, newp, newlen);
}

int sysctlbyname_new(const char *name, void *oldp, size_t *oldlenp,
                     void *newp, size_t newlen) {
    if (name && oldp) {
        if (!strcmp(name, "kern.osvariant_status")) {
            *(unsigned long long *)oldp = MACWS_OSVARIANT_STATUS_ALIVE;
            if (oldlenp) *oldlenp = sizeof(unsigned long long);
            return 0;
        }
        if (!strcmp(name, "kern.osproductversion")) {
            int r = macws_real_sysctlbyname(name, oldp, oldlenp, newp, newlen);
            if (r != 0) return r;
            char *v = (char *)oldp;
            if (oldlenp && *oldlenp >= 2 && v[0] == '1' && v[1] >= '4')
                v[1] -= 3;      // 16 -> 13
            else if (oldlenp && *oldlenp >= 2 && v[0] == '1')
                v[1] = '1';    // always macOS 11 otherwise
            return 0;
        }
    }
    return macws_real_sysctlbyname(name, oldp, oldlenp, newp, newlen);
}

// ---- os_variant hooks: exact proven-alive return values ----
bool hooked_os_variant_is_basesystem(const char *s){ (void)s; return false; }
bool hooked_os_variant_is_recovery(const char *s){ (void)s; return false; }
bool hooked_os_variant_allows_internal_security_policies(const char *s){ (void)s; return true; }
bool hooked_os_variant_has_internal_content(const char *s){ (void)s; return true; }
bool hooked_os_variant_has_internal_ui(const char *s){ (void)s; return true; }
bool hooked_os_variant_has_internal_diagnostics(const char *s){ (void)s; return true; }

// Interpose the high-level os_variant symbols (cross-library reachable) AND
// the sysctl source of the osvariant word. Order: sysctl first so any path
// that reads the raw word is pinned, then the family.
DYLD_INTERPOSE(sysctlbyname_new, sysctlbyname);
DYLD_INTERPOSE(hooked_os_variant_is_basesystem, os_variant_is_basesystem);
DYLD_INTERPOSE(hooked_os_variant_is_recovery, os_variant_is_recovery);
DYLD_INTERPOSE(hooked_os_variant_allows_internal_security_policies, os_variant_allows_internal_security_policies);
DYLD_INTERPOSE(hooked_os_variant_has_internal_content, os_variant_has_internal_content);
DYLD_INTERPOSE(hooked_os_variant_has_internal_ui, os_variant_has_internal_ui);
DYLD_INTERPOSE(hooked_os_variant_has_internal_diagnostics, os_variant_has_internal_diagnostics);
