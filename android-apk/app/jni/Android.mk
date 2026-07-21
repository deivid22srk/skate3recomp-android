LOCAL_PATH := $(call my-dir)

# Include subdirectory makefiles FIRST so SDL2 module is declared before
# main references it via LOCAL_SHARED_LIBRARIES.  Putting this after
# include $(BUILD_SHARED_LIBRARY) causes ndk-build to fail with
# "Module main depends on undefined modules: SDL2" because the SDL2
# module has not been registered yet when main is being resolved.
#
# Note: each subdir Android.mk resets LOCAL_PATH via its own
# $(call my-dir), so we must re-derive LOCAL_PATH here before declaring
# the 'main' module - otherwise LOCAL_SRC_FILES := src/main.c would be
# resolved against the last subdir's directory (e.g. the NDK's
# cpufeatures/), causing:
#   No rule to make target '.../cpufeatures/src/main.c'
include $(call all-subdir-makefiles)

LOCAL_PATH := $(call my-dir)

include $(CLEAR_VARS)
LOCAL_MODULE := main
LOCAL_SRC_FILES := $(LOCAL_PATH)/src/main.c
LOCAL_SHARED_LIBRARIES := SDL2
LOCAL_LDLIBS := -lGLESv1_CM -lGLESv2 -llog -landroid
include $(BUILD_SHARED_LIBRARY)
