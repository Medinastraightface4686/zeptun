TOP_PATH := $(call my-dir)
LOCAL_PATH := $(TOP_PATH)

ZEPTUN_PREBUILT := $(TOP_PATH)/zig-out/android/prebuilt/$(TARGET_ARCH_ABI)/libzeptun.a

include $(CLEAR_VARS)
LOCAL_MODULE := zeptun-prebuilt
LOCAL_SRC_FILES := zig-out/android/prebuilt/$(TARGET_ARCH_ABI)/libzeptun.a
LOCAL_EXPORT_C_INCLUDES := $(TOP_PATH)/include
include $(PREBUILT_STATIC_LIBRARY)

include $(CLEAR_VARS)
LOCAL_MODULE := zeptun-jni
LOCAL_SRC_FILES := src/jni/zeptun_jni.c
LOCAL_C_INCLUDES := $(TOP_PATH)/include
LOCAL_CFLAGS += -O3 -Wall -Wextra -Werror -std=c11
LOCAL_STATIC_LIBRARIES := zeptun-prebuilt
LOCAL_LDLIBS := -llog
LOCAL_LDFLAGS += -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384
include $(BUILD_SHARED_LIBRARY)
