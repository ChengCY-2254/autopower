THEOS_DEVICE_IP = localhost
THEOS_DEVICE_PORT = 2222
THEOS_DEVICE_USER = root
TARGET := iphone:clang:latest:14.0
ARCHS = arm64e
INSTALL_TARGET_PROCESSES = SpringBoard
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = autopower
autopower_FILES = Tweak.x \
	src/APSConfig.m \
	src/APSLog.m \
	src/APSGuard.m \
	src/APSLowPowerProvider.m \
	src/APSScreenProvider.m \
	src/APSLockProvider.m \
	src/APSStateMachine.m \
	src/APSInputSource.m \
	src/APSPlugin.m
autopower_CFLAGS = -fobjc-arc -Isrc

ifeq ($(FINALPACKAGE),1)
ADDITIONAL_CFLAGS += -O3 -ffunction-sections -fdata-sections
ADDITIONAL_LDFLAGS += -Wl,-dead_strip
# release：日志系统（APSLog + prefsLog + 日志设置页）整体不随包发布。
autopower_CFLAGS += -DAPSLOG_DISABLED
autopower_FILES := $(filter-out src/APSLog.m,$(autopower_FILES))
endif

BUNDLE_NAME = autopowerprefs
autopowerprefs_FILES = autopowerprefs/AutopowerPrefsController.m
autopowerprefs_RESOURCE_DIRS = autopowerprefs/Resources
autopowerprefs_INSTALL_PATH = /Library/PreferenceBundles
autopowerprefs_FRAMEWORKS = UIKit

autopowerprefs_LDFLAGS = -Wl,-undefined,dynamic_lookup
autopowerprefs_CFLAGS = -fobjc-arc

ifeq ($(FINALPACKAGE),1)
autopowerprefs_CFLAGS += -DAPSLOG_DISABLED
endif

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk
