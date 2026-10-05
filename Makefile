# THEOS_DEVICE_IP = 192.168.1.15
TARGET := iphone:clang:16.5:14.0
ARCHS := arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SlideCutPlus

SlideCutPlus_FILES = Tweak.x
SlideCutPlus_CFLAGS = -fobjc-arc
SlideCutPlus_FRAMEWORKS = UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
