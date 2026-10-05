// Umbrella header reconstructed for @import Darwin / <Darwin/Darwin.h>.
//
// The community iPhoneOS 14.5 SDK used by the on-device build ships no Darwin
// framework and no Darwin module, so the tree's `#import <Darwin/Darwin.h>`
// resolves to this file.  It must be a superset of the C / POSIX / Mach surface
// macPad actually uses: any declaration missing here surfaces much later and
// much more confusingly as
//
//     error: call to undeclared function 'malloc_size'
//     error: declaration of 'malloc_size' must be imported from module
//            'Darwin.malloc' before it is required
//     error: conflicting types for 'malloc_size'
//
// (macOS builds do not hit this because the real Darwin module is present.)
//
// Every include is guarded with __has_include so the same file works against
// the 14.5 on-device SDK, newer SDKs, and the macOS cross-build tree, where the
// set of available headers differs.
#ifndef __DARWIN_UMBRELLA_H__
#define __DARWIN_UMBRELLA_H__

#include <TargetConditionals.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <signal.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <time.h>
#include <unistd.h>

#if __has_include(<inttypes.h>)
#include <inttypes.h>
#endif
#if __has_include(<strings.h>)
#include <strings.h>
#endif
#if __has_include(<wchar.h>)
#include <wchar.h>
#endif
#if __has_include(<spawn.h>)
#include <spawn.h>
#endif
#if __has_include(<wordexp.h>)
#include <wordexp.h>
#endif
#if __has_include(<pthread.h>)
#include <pthread.h>
#endif
#if __has_include(<sched.h>)
#include <sched.h>
#endif

// System calls and BSD surface.
#if __has_include(<sys/types.h>)
#include <sys/types.h>
#endif
#if __has_include(<sys/stat.h>)
#include <sys/stat.h>
#endif
#if __has_include(<sys/wait.h>)
#include <sys/wait.h>
#endif
#if __has_include(<sys/mman.h>)
#include <sys/mman.h>
#endif
#if __has_include(<sys/sysctl.h>)
#include <sys/sysctl.h>
#endif
#if __has_include(<sys/event.h>)
#include <sys/event.h>
#endif
#if __has_include(<sys/time.h>)
#include <sys/time.h>
#endif
#if __has_include(<sys/resource.h>)
#include <sys/resource.h>
#endif
#if __has_include(<sys/socket.h>)
#include <sys/socket.h>
#endif
#if __has_include(<sys/un.h>)
#include <sys/un.h>
#endif
#if __has_include(<sys/uio.h>)
#include <sys/uio.h>
#endif
#if __has_include(<sys/ioctl.h>)
#include <sys/ioctl.h>
#endif
#if __has_include(<sys/param.h>)
#include <sys/param.h>
#endif
#if __has_include(<sys/mount.h>)
#include <sys/mount.h>
#endif
#if __has_include(<sys/statvfs.h>)
#include <sys/statvfs.h>
#endif
#if __has_include(<sys/utsname.h>)
#include <sys/utsname.h>
#endif
#if __has_include(<sys/select.h>)
#include <sys/select.h>
#endif
#if __has_include(<sys/dir.h>)
#include <sys/dir.h>
#endif
#if __has_include(<sys/attr.h>)
#include <sys/attr.h>
#endif
#if __has_include(<sys/clonefile.h>)
#include <sys/clonefile.h>
#endif
#if __has_include(<sys/kern_control.h>)
#include <sys/kern_control.h>
#endif

#if __has_include(<netinet/in.h>)
#include <netinet/in.h>
#endif
#if __has_include(<arpa/inet.h>)
#include <arpa/inet.h>
#endif
#if __has_include(<netdb.h>)
#include <netdb.h>
#endif

// libSystem extensions.  malloc_size() is the one that broke the libmachook
// build; crt_externs and ptrauth are needed by the hook/jit sources.
#if __has_include(<malloc/malloc.h>)
#include <malloc/malloc.h>
#endif
#if __has_include(<crt_externs.h>)
#include <crt_externs.h>
#endif
#if __has_include(<ptrauth.h>)
#include <ptrauth.h>
#endif
#if __has_include(<dlfcn.h>)
#include <dlfcn.h>
#endif
#if __has_include(<uuid/uuid.h>)
#include <uuid/uuid.h>
#endif
#if __has_include(<os/lock.h>)
#include <os/lock.h>
#endif
#if __has_include(<os/availability.h>)
#include <os/availability.h>
#endif

// Mach.  mach_vm_* / mach_*_t are used heavily by libmachook.
#if __has_include(<mach/mach.h>)
#include <mach/mach.h>
#endif
#if __has_include(<mach/mach_init.h>)
#include <mach/mach_init.h>
#endif
#if __has_include(<mach/mach_host.h>)
#include <mach/mach_host.h>
#endif
#if __has_include(<mach/mach_port.h>)
#include <mach/mach_port.h>
#endif
#if __has_include(<mach/mach_time.h>)
#include <mach/mach_time.h>
#endif
// iPhoneOS ships this path as an unsupported-header sentinel.
// mac_hooks.m owns its explicit mach_vm_* declarations for the iOS target.
#if TARGET_OS_OSX && __has_include(<mach/mach_vm.h>)
#include <mach/mach_vm.h>
#endif
#if __has_include(<mach/vm_map.h>)
#include <mach/vm_map.h>
#endif
#if __has_include(<mach/vm_statistics.h>)
#include <mach/vm_statistics.h>
#endif
#if __has_include(<mach/task.h>)
#include <mach/task.h>
#endif
#if __has_include(<mach/thread_act.h>)
#include <mach/thread_act.h>
#endif
#if __has_include(<mach/semaphore.h>)
#include <mach/semaphore.h>
#endif
#if __has_include(<mach/host_info.h>)
#include <mach/host_info.h>
#endif
#if __has_include(<mach/processor_info.h>)
#include <mach/processor_info.h>
#endif
#if __has_include(<mach/error.h>)
#include <mach/error.h>
#endif

// Mach-O.  The community SDK has no `MachO` module, so the tree's
// `#import <MachO/MachO.h>` was rewritten to these by fix_macho_import.py;
// keeping them here means files that only import Darwin still get them.
#if __has_include(<mach-o/dyld.h>)
#include <mach-o/dyld.h>
#endif
#if __has_include(<mach-o/loader.h>)
#include <mach-o/loader.h>
#endif
#if __has_include(<mach-o/nlist.h>)
#include <mach-o/nlist.h>
#endif
#if __has_include(<mach-o/getsect.h>)
#include <mach-o/getsect.h>
#endif
#if __has_include(<mach-o/fat.h>)
#include <mach-o/fat.h>
#endif
#if __has_include(<mach-o/arch.h>)
#include <mach-o/arch.h>
#endif
#if __has_include(<mach-o/swap.h>)
#include <mach-o/swap.h>
#endif
#if __has_include(<mach-o/dyld_images.h>)
#include <mach-o/dyld_images.h>
#endif

#endif /* __DARWIN_UMBRELLA_H__ */
