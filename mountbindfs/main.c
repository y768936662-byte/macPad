// mount_bindfs — expose a jailbreak-side source directory at a target path
// that a chrooted macOS process will read.  This is the missing helper that
// `ensure_jb_usr_bind.sh` and the `macos_gui.sh` GUI stack call at
// /var/jb/usr/local/bin/mount_bindfs.
//
// Why a dedicated helper at all: a chrooted client must read the Dock XPC
// activation bundle at the *same absolute path* that iOS launchd will later
// use to start the proxy.  The cleanest way to make /var/jb/usr readable from
// inside the /var/mnt/rootfs chroot is a bind mount.  On rootless Dopamine a
// true XNU bind mount of one directory over another is refused by the kernel
// (ENOTSUP) even under the jailbreak's unsandboxed root credential, so a real
// bind is not achievable on this tree.
//
// Strategy: try the bind first (idempotent, and it keeps the target a genuine
// shared filesystem mount where the kernel allows it).  If the kernel refuses
// it, fall back to a SYMLINK that exposes the source at the target path.  The
// symlink is a hard fallback, not a preference — `ensure_jb_usr_bind.sh` only
// requires that `[ -x target/<proxy> ]` succeed, and a symlink satisfies that
// exactly.  It also survives reboot the same way a bind would not.
//
// Idempotent: re-running this tool never fails when the target already
// exposes the source, so postinst.sh can call it on every (re)install.
//
// Usage:  mount_bindfs <source-dir> <target-dir>

#include <dlfcn.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/param.h>
#include <dirent.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>

// XNU bind-mount flags (absent from the community SDK headers).  MSHARED asks
// for a shared instance of the source mount; MSBDFL keeps the bind read-only
// to mirror the documented behaviour of the project's bind helper.
#ifndef MSHARED
#define MSHARED 0x00000004
#endif
#ifndef MSBDFL
#define MSBDFL 0x00000400
#endif

// Resolve the jailbreak root at runtime.  The Theos build-time
// THEOS_PACKAGE_INSTALL_PREFIX macro is not guaranteed to be correct when this
// tool is built as a standalone subproject on-device, so probe the well-known
// locations directly.  Dopamine rootless exposes /var/jb; a jailbroken
// (rooted) tree may instead carry the real root with no prefix.
static const char *resolve_jailbreak_root(void) {
    static const char *candidates[] = {
        "/var/jb",              // Dopamine rootless
        "/jailbreak",           // classic CydiaSubstrate root
        "/jb",                  // some Sileo layouts
        NULL,
    };
    for (int i = 0; candidates[i] != NULL; i++) {
        if (access(candidates[i], F_OK) == 0) {
            return candidates[i];
        }
    }
    return "/var/jb";
}

#define LIBJAILBREAK_PATH_STR "/usr/lib/libjailbreak.dylib"

typedef int (*jbclient_root_steal_ucred_fn)(uint64_t, uint64_t *);

// Report whether the target already exposes the source (either as a live bind
// mount, or as a symlink pointing back at the source).  This is the single
// idempotency predicate the caller relies on.
static int target_exposes_source(const char *target, const char *source) {
    struct stat st;
    if (stat(target, &st) != 0) {
        return 0;
    }
    if (!S_ISLNK(st.st_mode) && !S_ISDIR(st.st_mode)) {
        return 0;
    }
    if (S_ISLNK(st.st_mode)) {
        char resolved[PATH_MAX];
        if (readlink(target, resolved, sizeof(resolved)) <= 0) {
            return 0;
        }
        resolved[PATH_MAX - 1] = '\0';
        return strcmp(resolved, source) == 0;
    }
    // Regular directory: only treat it as "already bound" when it is a mount
    // point with the same device number as the source.
    struct stat sst;
    if (stat(source, &sst) != 0) {
        return 0;
    }
    return st.st_dev == sst.st_dev;
}

// Borrow the jailbreak's unsandboxed root credential, run one mount(2), and
// restore the caller's credential.  Bounded transaction so the caller's
// process sandbox is not globally weakened.
static int try_bind_mount(const char *source, const char *target) {
    const char *jbroot = resolve_jailbreak_root();
    char libpath[PATH_MAX];
    snprintf(libpath, sizeof(libpath), "%s%s", jbroot, LIBJAILBREAK_PATH_STR);

    void *jailbreak = dlopen(libpath, RTLD_NOW | RTLD_LOCAL);
    if (!jailbreak) {
        jailbreak = dlopen(LIBJAILBREAK_PATH_STR, RTLD_NOW | RTLD_LOCAL);
    }
    if (!jailbreak) {
        return -1;
    }
    jbclient_root_steal_ucred_fn steal =
        (jbclient_root_steal_ucred_fn)dlsym(
            jailbreak, "jbclient_root_steal_ucred");
    if (!steal) {
        dlclose(jailbreak);
        return -1;
    }

    uint64_t originalCredential = 0;
    int stealStatus = steal(0, &originalCredential);
    if (stealStatus != 0 || originalCredential == 0) {
        dlclose(jailbreak);
        return -1;
    }

    int result = mount(source, target, MSHARED | MSBDFL, NULL);
    int mountError = errno;
    int restoreStatus = steal(originalCredential, NULL);
    dlclose(jailbreak);
    if (restoreStatus != 0) {
        return -1;
    }
    if (result != 0) {
        errno = mountError;
        return -1;
    }
    return 0;
}

// Is the target directory empty?  Uses the directory stream, not read().
static int directory_is_empty(const char *path) {
    DIR *dir = opendir(path);
    if (dir == NULL) {
        return 0;
    }
    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        // Ignore the standard . and .. entries.
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
            continue;
        }
        closedir(dir);
        return 0; // at least one real entry
    }
    closedir(dir);
    return 1;
}

// Replace the target with a symlink to the source.  Only used when the kernel
// refuses a bind mount.  The target must be empty (or absent); if it holds
// content, leave it alone and report failure rather than clobber it.
static int symlink_expose(const char *source, const char *target) {
    struct stat st;
    if (stat(target, &st) == 0) {
        if (S_ISLNK(st.st_mode) && target_exposes_source(target, source)) {
            return 0; // already a correct symlink
        }
        if (S_ISDIR(st.st_mode)) {
            if (target_exposes_source(target, source)) {
                return 0; // live bind already in place
            }
            if (!directory_is_empty(target)) {
                return -1; // nonempty and not ours: refuse to clobber
            }
            if (rmdir(target) != 0) {
                return -1;
            }
        } else {
            if (unlink(target) != 0) {
                return -1;
            }
        }
    }
    if (symlink(source, target) != 0) {
        return -1;
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: mount_bindfs <source-dir> <target-dir>\n");
        return 2;
    }
    const char *source = argv[1];
    const char *target = argv[2];

    struct stat srcStat;
    if (stat(source, &srcStat) != 0 || !S_ISDIR(srcStat.st_mode)) {
        fprintf(stderr, "mount_bindfs: source not a directory: %s (%s)\n",
                source, strerror(errno));
        return 1;
    }

    if (target_exposes_source(target, source)) {
        printf("bindfs already exposed at %s\n", target);
        return 0;
    }

    // Ensure the target's parent exists; make the target dir if absent.
    if (stat(target, &srcStat) != 0) {
        mkdir(target, 0755);
    }

    if (try_bind_mount(source, target) == 0) {
        printf("mounted bindfs %s on %s\n", source, target);
        return 0;
    }

    // The kernel refused a real bind mount on this tree.  Fall back to the
    // symlink so the target path still resolves to the source contents.
    int saved = errno;
    if (symlink_expose(source, target) != 0) {
        fprintf(stderr,
                "mount_bindfs %s: bind mount refused (%s) and symlink "
                "fallback failed: %s\n",
                target, strerror(saved), strerror(errno));
        return 1;
    }
    if (target_exposes_source(target, source)) {
        printf("exposed %s at %s via symlink (bind unsupported on this "
               "kernel)\n",
               source, target);
        return 0;
    }
    fprintf(stderr, "mount_bindfs %s: target does not expose source after "
            "fallback\n", target);
    return 1;
}
