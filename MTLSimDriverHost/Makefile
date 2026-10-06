# Default: iOS bundle for the on-device (outside-chroot) install tree.
# The macOS (chroot-side) host build is produced by ci/build_mtl_host_macos.sh,
# which overrides TARGET to macosx:clang so the binary carries
# LC_BUILD_VERSION platform=1 (macOS) — required for dyld inside the chroot
# (see analysis/codex-q7-20261006.md, evidence H/I: iOS platform in chroot
# is rejected; byte-patching platform crashes WSInitialize).
TARGET ?= iphone:clang:latest:14.0
ifeq ($(TARGET),macosx:clang)
# macOS SDK ships xpc/ headers natively; the -isystem vendored iOS xpc path
# would shadow them with iOS-only declarations.
MTLSimDriverHost_CFLAGS = -fobjc-arc -DMACWS_MTLHOST_MACOS_BUILD=1
else
MTLSimDriverHost_CFLAGS = -fobjc-arc -isystem $(CURDIR)/../vendor/ios-xpc
endif
ARCHS = arm64
include ../config/production.mk
include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = MTLSimDriverHost

MTLSimDriverHost_DYNAMIC_LIBRARY = 0
MTLSimDriverHost_BUNDLE_EXTENSION = xpc
MTLSimDriverHost_FILES = main.x
MTLSimDriverHost_FRAMEWORKS = Foundation Metal MetalPerformanceShaders IOSurface
MTLSimDriverHost_CODESIGN_FLAGS = -S../entitlements.plist
MTLSimDriverHost_INSTALL_PATH = /usr/macOS/Frameworks/MTLSimDriver.framework/XPCServices

include $(THEOS_MAKE_PATH)/bundle.mk
