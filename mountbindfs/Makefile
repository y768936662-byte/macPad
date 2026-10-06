# mount_bindfs — the missing Dopamine bind-mount helper that ensure_jb_usr_bind.sh
# and macos_gui.sh call at /var/jb/usr/local/bin/mount_bindfs.
#
# The community rootless Dopamine tree does not ship this helper, so the chrooted
# macOS GUI stack cannot expose /var/jb/usr (and the Dock XPC activation bundle)
# to the chroot and `macos_gui.sh production` aborts with
# "mount_bindfs is unavailable".  Build it here as an iOS tool that borrows the
# jailbreak's unsandboxed root credential around mount(2) and performs a real
# XNU bind-mount (MSHARED | MSBDFL).
#
# Install path is /usr/local/bin (-> /var/jb/usr/local/bin/mount_bindfs), the
# exact location the shell scripts probe.  Reuse the same narrow identity as
# mountdevfs (bindfs helper): the mount authority comes from main.c's bounded
# libjailbreak credential transaction, never from a broad macOS-process
# signing profile.
TARGET := iphone:clang:latest:14.0
ARCHS = arm64
include ../config/production.mk
include $(THEOS)/makefiles/common.mk

TOOL_NAME = mount_bindfs

mount_bindfs_FILES = main.c
mount_bindfs_CODESIGN_FLAGS = -Sentitlements.plist
mount_bindfs_INSTALL_PATH = /usr/local/bin

include $(THEOS_MAKE_PATH)/tool.mk
