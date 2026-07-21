LOCAL_PATH := $(call my-dir)

# LOCAL_PATH at this point is the absolute path of this directory
# (android-apk/app/jni).  Save it in a variable that is not affected
# by later subdir includes, since each subdir Android.mk will re-run
# $(call my-dir) and reset LOCAL_PATH to its own directory.
MAIN_LOCAL_PATH := $(LOCAL_PATH)

# Include subdirectory makefiles FIRST so SDL2 module is declared before
# main references it via LOCAL_SHARED_LIBRARIES.
include $(call all-subdir-makefiles)

# Re-set LOCAL_PATH for the main module declaration (it was reset by the
# subdir includes above).
LOCAL_PATH := $(MAIN_LOCAL_PATH)

include $(CLEAR_VARS)
LOCAL_MODULE := main
LOCAL_SRC_FILES := src/main.c
LOCAL_SHARED_LIBRARIES := SDL2
LOCAL_LDLIBS := -lGLESv1_CM -lGLESv2 -llog -landroid
include $(BUILD_SHARED_LIBRARY)
