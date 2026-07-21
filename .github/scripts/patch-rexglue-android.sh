#!/usr/bin/env bash
# Patch rexglue-sdk to enable the SDL3 backend on Android instead of GTK/X11.
#
# The upstream SDK only enables SDL3 on Apple.  On Android (and any other
# non-Linux-desktop target) we need SDL3 too, because GTK/X11 are not
# available.  This patch is applied in CI before cmake configure.
#
# Idempotent: running twice is a no-op.
set -euo pipefail

SDK_DIR="${1:-third_party/rexglue-sdk}"
UI_CMAKE="$SDK_DIR/src/ui/CMakeLists.txt"
THIRDPARTY_CMAKE="$SDK_DIR/thirdparty/CMakeLists.txt"

if [ ! -f "$UI_CMAKE" ]; then
    echo "::error::$UI_CMAKE not found"
    exit 1
fi

# 1. src/ui/CMakeLists.txt: use SDL3 platform sources on Android too.
python3 - "$UI_CMAKE" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
s = p.read_text()
if "APPLE OR ANDROID" in s:
    print(f"::notice::{p} already patched")
else:
    s = s.replace("elseif(APPLE)\n    set(REXUI_PLATFORM_SOURCES",
                  "elseif(APPLE OR ANDROID)\n    set(REXUI_PLATFORM_SOURCES")
    s = s.replace("elseif(APPLE)\n    target_link_libraries(rexui PUBLIC SDL3::SDL3)",
                  "elseif(APPLE OR ANDROID)\n    target_link_libraries(rexui PUBLIC SDL3::SDL3)")
    p.write_text(s)
    print(f"::notice::{p} patched: APPLE -> APPLE OR ANDROID")
PY

# 2. thirdparty/CMakeLists.txt: enable SDL3 video subsystem on Android.
python3 - "$THIRDPARTY_CMAKE" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
s = p.read_text()
if "APPLE OR ANDROID" in s and "SDL_VIDEO" in s:
    # already patched
    pass
else:
    old = """if(APPLE)
    set(SDL_VIDEO ON CACHE BOOL "" FORCE)
else()
    set(SDL_VIDEO OFF CACHE BOOL "" FORCE)
endif()"""
    new = """if(APPLE OR ANDROID)
    set(SDL_VIDEO ON CACHE BOOL "" FORCE)
else()
    set(SDL_VIDEO OFF CACHE BOOL "" FORCE)
endif()"""
    if old in s:
        s = s.replace(old, new)
        p.write_text(s)
        print(f"::notice::{p} patched: SDL_VIDEO enabled for Android")
    else:
        print(f"::warning::{p} SDL_VIDEO block not found, leaving unchanged")
PY

# 3. thirdparty/CMakeLists.txt: enable Vulkan on Android.
python3 - "$THIRDPARTY_CMAKE" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
s = p.read_text()
old = 'set(SDL_VULKAN OFF CACHE BOOL "" FORCE)'
new = 'set(SDL_VULKAN ON CACHE BOOL "" FORCE)'
if 'set(SDL_VULKAN ON' in s:
    print(f"::notice::{p} SDL_VULKAN already enabled")
elif old in s:
    s = s.replace(old, new)
    p.write_text(s)
    print(f"::notice::{p} patched: SDL_VULKAN enabled")
else:
    print(f"::notice::{p} SDL_VULKAN block not found")
PY

# 4. cmake/rexglue_helpers.cmake: skip GTK3 lookup on Android and use the
#    SDL3 main entry point instead of windowed_app_main_posix.cpp.
HELPERS_CMAKE="$SDK_DIR/cmake/rexglue_helpers.cmake"
python3 - "$HELPERS_CMAKE" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
s = p.read_text()
changed = False

# 4a. rexglue_apply_target_settings: replace `if(UNIX AND NOT APPLE)` (the
#     GTK3 block) with `if(UNIX AND NOT APPLE AND NOT ANDROID)`.
old1 = "    if(UNIX AND NOT APPLE)\n        find_package(PkgConfig REQUIRED)\n        pkg_check_modules(GTK3 REQUIRED gtk+-3.0)"
new1 = "    if(UNIX AND NOT APPLE AND NOT ANDROID)\n        find_package(PkgConfig REQUIRED)\n        pkg_check_modules(GTK3 REQUIRED gtk+-3.0)"
if old1 in s:
    s = s.replace(old1, new1)
    changed = True

# 4b. rexglue_configure_target: replace the posix main source with the SDL
#     one on Android (APPLE already uses windowed_app_main_sdl.cpp).
old2 = "    elseif(APPLE)\n        target_sources(${target_name} PRIVATE\n            ${REXGLUE_SHARE_DIR}/windowed_app_main_sdl.cpp)\n    else()\n        target_sources(${target_name} PRIVATE\n            ${REXGLUE_SHARE_DIR}/windowed_app_main_posix.cpp)\n    endif()"
new2 = "    elseif(APPLE OR ANDROID)\n        target_sources(${target_name} PRIVATE\n            ${REXGLUE_SHARE_DIR}/windowed_app_main_sdl.cpp)\n    else()\n        target_sources(${target_name} PRIVATE\n            ${REXGLUE_SHARE_DIR}/windowed_app_main_posix.cpp)\n    endif()"
if old2 in s:
    s = s.replace(old2, new2)
    changed = True
elif "elseif(APPLE OR ANDROID)" in s:
    # already patched
    pass

# 4c. rexglue_configure_target: replace `elseif(UNIX AND NOT APPLE)` RPATH
#     block with `elseif(UNIX AND NOT APPLE AND NOT ANDROID)` so we don't
#     try to set $ORIGIN RPATH on a shared library (Android loads via
#     standard library search paths).
old3 = "    elseif(UNIX AND NOT APPLE)\n        set_target_properties(${target_name} PROPERTIES\n            INSTALL_RPATH \"$ORIGIN\""
new3 = "    elseif(UNIX AND NOT APPLE AND NOT ANDROID)\n        set_target_properties(${target_name} PROPERTIES\n            INSTALL_RPATH \"$ORIGIN\""
if old3 in s:
    s = s.replace(old3, new3)
    changed = True

if changed:
    p.write_text(s)
    print(f"::notice::{p} patched: GTK3 skipped, SDL3 main used, RPATH skipped on Android")
else:
    print(f"::notice::{p} already patched (or pattern not found)")
PY

# 5. Provide <rex/main_android.h> stub.  rexglue-sdk's threading_posix.cpp
#    and memory_posix.cpp reference rex::GetAndroidApiLevel() but the SDK
#    never ships the header.  We provide a minimal implementation that
#    returns our minimum target API level (29) so the dlopen-based feature
#    detection paths in those files stay disabled at runtime.
MAIN_ANDROID_H="$SDK_DIR/include/rex/main_android.h"
mkdir -p "$SDK_DIR/include/rex"
cat > "$MAIN_ANDROID_H" <<'H'
// SPDX-License-Identifier: BSD-3-Clause
// Android compatibility shim for rexglue-sdk.
//
// The upstream SDK's threading_posix.cpp and memory_posix.cpp call
// rex::GetAndroidApiLevel() but the corresponding header is missing.
// This stub returns a conservative API level (29) so the dlopen-based
// feature detection paths in those files stay disabled at runtime.
#pragma once

#include <cstddef>

namespace rex {

// Returns the device's Android API level, or 29 (our minimum target) if
// the JNI lookup has not been wired up by the host application.
inline int GetAndroidApiLevel() {
    return 29;
}

}  // namespace rex
H
echo "::notice::$MAIN_ANDROID_H written (GetAndroidApiLevel stub)"

# 6. Drop fiber_posix.cpp and exception_handler_posix.cpp from rexcore on
#    Android.  Both #include <ucontext.h>, which the NDK ships at
#    <sys/ucontext.h> with incompatible typedefs (sigcontext-based
#    mcontext_t, struct ucontext ucontext_t).  Providing our own shim
#    conflicts with the NDK's.  exception_handler_posix.cpp additionally
#    uses x86_64-only REG_RIP/REG_RAX/... which don't exist on arm64.
#    Both files implement non-essential primitives for the current stub
#    build phase, so the simplest path is to exclude them.
#
#    Note: list(REMOVE_ITEM) cannot be used here because rexcore is an
#    OBJECT library whose sources are consumed by add_library() at line 4.
#    Instead, we split the existing elseif(UNIX) target_sources() block
#    so that on Android we add a stub list without the two offending files.
CORE_CMAKE="$SDK_DIR/src/core/CMakeLists.txt"
python3 - "$CORE_CMAKE" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
s = p.read_text()
if "REX_ANDROID_CORE_POSIX_SOURCES" in s:
    print(f"::notice::{p} already has Android-specific core posix sources split")
else:
    # Original block:
    #   elseif(UNIX)
    #       target_sources(rexcore PRIVATE
    #           atomic_posix.cpp
    #           ... (17 files including exception_handler_posix.cpp and fiber_posix.cpp)
    #           threading_posix.cpp
    #       )
    old_block = """elseif(UNIX)
    target_sources(rexcore PRIVATE
        atomic_posix.cpp
        clock_posix.cpp
        dbg_posix.cpp
        dynlib_posix.cpp
        exception_handler_posix.cpp
        filesystem_posix.cpp
        fiber_posix.cpp
        mapped_memory_posix.cpp
        math_gcc.cpp
        memory_posix.cpp
        seh_posix.cpp
        socket_posix.cpp
        string_posix.cpp
        system_posix.cpp
        threading_posix.cpp
    )
endif()"""
    new_block = """elseif(UNIX AND NOT ANDROID)
    # Full POSIX source set - requires ucontext.h (for fibers) and
    # x86_64-only register macros (for exception_handler).
    target_sources(rexcore PRIVATE
        atomic_posix.cpp
        clock_posix.cpp
        dbg_posix.cpp
        dynlib_posix.cpp
        exception_handler_posix.cpp
        filesystem_posix.cpp
        fiber_posix.cpp
        mapped_memory_posix.cpp
        math_gcc.cpp
        memory_posix.cpp
        seh_posix.cpp
        socket_posix.cpp
        string_posix.cpp
        system_posix.cpp
        threading_posix.cpp
    )
elseif(ANDROID)
    # REX_ANDROID_CORE_POSIX_SOURCES: reduced POSIX source set for Android.
    # - fiber_posix.cpp excluded: <ucontext.h> not in NDK, conflicts with
    #   sys/ucontext.h's typedefs.
    # - exception_handler_posix.cpp excluded: uses x86_64-only REG_RIP /
    #   REG_RAX / ... which don't exist on arm64.
    target_sources(rexcore PRIVATE
        atomic_posix.cpp
        clock_posix.cpp
        dbg_posix.cpp
        dynlib_posix.cpp
        filesystem_posix.cpp
        mapped_memory_posix.cpp
        math_gcc.cpp
        memory_posix.cpp
        seh_posix.cpp
        socket_posix.cpp
        string_posix.cpp
        system_posix.cpp
        threading_posix.cpp
    )
endif()"""
    if old_block in s:
        s = s.replace(old_block, new_block)
        p.write_text(s)
        print(f"::notice::{p} patched: split elseif(UNIX) into UNIX-NOT-ANDROID + ANDROID branches")
    else:
        print(f"::warning::{p} could not find elseif(UNIX) target_sources block to split")
PY

# 7. Patch src/core/memory_posix.cpp: replace <linux/ashmem.h> (missing
#    from the NDK) with inline definitions of the constants it actually
#    uses, and add the missing #include <rex/main_android.h>.
MEM_POSIX="$SDK_DIR/src/core/memory_posix.cpp"
python3 - "$MEM_POSIX" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
s = p.read_text()

# 7a. Replace <linux/ashmem.h> with inline constants.  Use #undef first
#     to avoid redefinition warnings against <asm-generic/ioctl.h>.
old_ashmem = '#include <linux/ashmem.h>'
new_ashmem = '''// <linux/ashmem.h> is not shipped by the Android NDK; define the few
// constants memory_posix.cpp actually uses inline.  _IOWR is already
// provided by <asm-generic/ioctl.h> (via <sys/ioctl.h>), so we only
// define the ashmem-specific ioctls on top of it.
#include <sys/ioctl.h>
#ifndef ASHMEM_NAME_LEN
#define ASHMEM_NAME_LEN 256
#endif
#ifndef ASHMEM_NAME_DEF
#define ASHMEM_NAME_DEF "ashmem"
#endif
#ifndef ASHMEM_SET_NAME
#define ASHMEM_SET_NAME _IOWR(0x98, 1, char[ASHMEM_NAME_LEN])
#endif
#ifndef ASHMEM_SET_SIZE
#define ASHMEM_SET_SIZE _IOWR(0x98, 3, size_t)
#endif'''
if 'ASHMEM_SET_NAME _IOWR(0x98, 1, char[ASHMEM_NAME_LEN])' in s:
    print(f"::notice::{p} already has ashmem constants inlined")
elif old_ashmem in s:
    s = s.replace(old_ashmem, new_ashmem)
    print(f"::notice::{p} patched: ashmem.h replaced with inline constants")
else:
    print(f"::warning::{p} ashmem.h include not found")

# 7b. Add #include <rex/main_android.h> near the top of the Android block.
old_inc = '// #include "xenia/base/main_android.h"'
new_inc = '''// #include "xenia/base/main_android.h"
#include <rex/main_android.h>'''
if '#include <rex/main_android.h>' in s:
    print(f"::notice::{p} already includes rex/main_android.h")
elif old_inc in s:
    s = s.replace(old_inc, new_inc)
    print(f"::notice::{p} patched: added #include <rex/main_android.h>")
else:
    print(f"::warning::{p} xenia main_android comment not found")

p.write_text(s)
PY

# 8. Patch src/core/threading_posix.cpp: PTHREAD_MUTEX_ROBUST and
#    pthread_mutex_consistent are not available in Android's Bionic libc.
#    Stub them out on Android (the rexglue code path that uses them is
#    for crash-recovery of held mutexes, which is non-essential for the
#    current stub build phase).
THREAD_POSIX="$SDK_DIR/src/core/threading_posix.cpp"
python3 - "$THREAD_POSIX" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
s = p.read_text()
if "REX_ANDROID_NO_ROBUST_MUTEX" in s:
    print(f"::notice::{p} already has Android robust-mutex stub")
else:
    # 8a. Wrap the setrobust call site.  Original:
    #       if (pthread_mutexattr_setrobust(&attr, PTHREAD_MUTEX_ROBUST) == 0) {
    #     The `if (...)` header must remain valid C++ on both branches, so
    #     we keep the `if (` and `{` outside the #if and only guard the
    #     condition expression.  On Android the condition collapses to
    #     `0 == 0` (false), so the body is skipped at runtime.
    s = s.replace(
        "if (pthread_mutexattr_setrobust(&attr, PTHREAD_MUTEX_ROBUST) == 0) {",
        "#if defined(__ANDROID__)\n      if (false) {  // REX_ANDROID_NO_ROBUST_MUTEX: robust mutexes unavailable in Bionic\n#else\n      if (pthread_mutexattr_setrobust(&attr, PTHREAD_MUTEX_ROBUST) == 0) {\n#endif"
    )
    # 8b. Wrap the two pthread_mutex_consistent() calls.  These are
    #     statement expressions; we can simply #if them out on Android.
    s = s.replace(
        "pthread_mutex_consistent(native_mutex);",
        "#if !defined(__ANDROID__)\n      pthread_mutex_consistent(native_mutex);\n#endif"
    )
    p.write_text(s)
    print(f"::notice::{p} patched: robust-mutex calls guarded on Android (REX_ANDROID_NO_ROBUST_MUTEX)")
PY

# 9. Link libandroid on Android (needed for ASharedMemory_create and the
#    android_* activity symbols used elsewhere in the SDK).  Also exclude
#    Android from the `pthread dl rt` link block on UNIX, because:
#      - Bionic libc has pthread built-in (no -lpthread needed; the linker
#        errors with "unable to find library -lpthread")
#      - Bionic has no librt (the linker errors with
#        "unable to find library -lrt")
#    Non-Android UNIX platforms (Linux desktop, macOS) keep the original
#    pthread/dl/rt linkage.
python3 - "$CORE_CMAKE" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
s = p.read_text()
if "target_link_libraries(rexcore PRIVATE android)" in s:
    print(f"::notice::{p} already links libandroid")
else:
    old = """if(UNIX)
    target_link_libraries(rexcore PRIVATE pthread dl)
    if(NOT APPLE)
        target_link_libraries(rexcore PRIVATE rt)
    endif()
elseif(WIN32)
    target_link_libraries(rexcore PUBLIC ws2_32)
endif()"""
    new = """if(UNIX AND NOT ANDROID)
    # Desktop POSIX: link libpthread, libdl, librt explicitly.
    # Android/Bionic has pthread built into libc and has no librt, so
    # adding -lpthread / -lrt there fails at link time with
    # "unable to find library -lpthread" / "-lrt".
    target_link_libraries(rexcore PRIVATE pthread dl)
    if(NOT APPLE)
        target_link_libraries(rexcore PRIVATE rt)
    endif()
elseif(ANDROID)
    target_link_libraries(rexcore PRIVATE dl android log)
elseif(WIN32)
    target_link_libraries(rexcore PUBLIC ws2_32)
endif()"""
    if old in s:
        s = s.replace(old, new)
        p.write_text(s)
        print(f"::notice::{p} patched: pthread/rt excluded on Android, libandroid + liblog added")
    else:
        print(f"::warning::{p} UNIX/WIN32 link block not found, libandroid not added")
PY

# 10. Provide include/rex/ui/surface_android.h.  The SDK references this
#     header (and the AndroidNativeWindowSurface class it should declare)
#     from src/ui/vulkan/vulkan_presenter.cpp but never actually ships it.
#     Provide a minimal stub that wraps ANativeWindow* from the NDK's
#     <android/native_window.h>.  At runtime SDL3 will create the
#     VkSurfaceKHR directly via SDL_Vulkan_CreateSurface, so this class
#     is only needed to make the file compile.
SURFACE_ANDROID_H="$SDK_DIR/include/rex/ui/surface_android.h"
mkdir -p "$SDK_DIR/include/rex/ui"
cat > "$SURFACE_ANDROID_H" <<'H'
// SPDX-License-Identifier: BSD-3-Clause
// Android compatibility shim for rexglue-sdk.
//
// rexglue-sdk's src/ui/vulkan/vulkan_presenter.cpp references
// AndroidNativeWindowSurface on REX_PLATFORM_ANDROID but the SDK never
// shipped the corresponding header.  This stub declares the class with
// the same surface() accessor used by vulkan_presenter.cpp's
// vkCreateAndroidSurfaceKHR call site, wrapping ANativeWindow* from the
// NDK's <android/native_window.h>.
#pragma once

#include <rex/ui/surface.h>

#include <android/native_window.h>

namespace rex {
namespace ui {

class AndroidNativeWindowSurface final : public Surface {
 public:
  explicit AndroidNativeWindowSurface(ANativeWindow* window)
      : window_(window) {}

  TypeIndex GetType() const override {
    return kTypeIndex_AndroidNativeWindow;
  }

  ANativeWindow* window() const { return window_; }

 protected:
  bool GetSizeImpl(uint32_t& width_out, uint32_t& height_out) const override {
    if (!window_) {
      width_out = 0;
      height_out = 0;
      return false;
    }
    width_out = static_cast<uint32_t>(ANativeWindow_getWidth(window_));
    height_out = static_cast<uint32_t>(ANativeWindow_getHeight(window_));
    return width_out > 0 && height_out > 0;
  }

 private:
  ANativeWindow* window_;
};

}  // namespace ui
}  // namespace rex
H
echo "::notice::$SURFACE_ANDROID_H written (AndroidNativeWindowSurface stub)"

# 11. Patch thirdparty/CMakeLists.txt so FFmpeg AArch64 assembly objects
#     are built with -fPIC on Android.  Without it, the resulting
#     relocations are absolute (R_AARCH64_ADR_PREL_PG_HI21 / ADD_ABS_LO12_NC)
#     and lld rejects them when linking liblibavcodec.a into the shared
#     librexruntime.so:
#       ld.lld: error: relocation R_AARCH64_ADR_PREL_PG_HI21 cannot be
#       used against symbol 'ff_cos_32'; recompile with -fPIC
#     CMAKE_POSITION_INDEPENDENT_CODE ON (set globally at CMakeLists.txt:118)
#     only applies -fPIC to C/C++ targets, NOT to ASM.  The existing
#     `set(CMAKE_ASM_FLAGS "${CMAKE_ASM_FLAGS} -march=armv8-a")` block
#     in the ARM64 FFmpeg setup section needs -fPIC appended on Android.
THIRDPARTY_CMAKE="$SDK_DIR/thirdparty/CMakeLists.txt"
python3 - "$THIRDPARTY_CMAKE" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
s = p.read_text()
old = """if(IS_ARM64)
  enable_language(ASM)
  set(CMAKE_ASM_FLAGS "${CMAKE_ASM_FLAGS} -march=armv8-a")
endif()"""
new = """if(IS_ARM64)
  enable_language(ASM)
  set(CMAKE_ASM_FLAGS "${CMAKE_ASM_FLAGS} -march=armv8-a")
  # ASM sources need -fPIC explicitly on Android - CMAKE_POSITION_INDEPENDENT_CODE
  # only injects -fPIC into C/C++ targets, not ASM.  Without it, lld rejects
  # the absolute AArch64 relocations emitted by NEON .S files when linking
  # liblibavcodec.a into the shared librexruntime.so.
  if(ANDROID)
    set(CMAKE_ASM_FLAGS "${CMAKE_ASM_FLAGS} -fPIC")
  endif()
endif()"""
if "ASM sources need -fPIC explicitly on Android" in s:
    print(f"::notice::{p} already has -fPIC for ASM on Android")
elif old in s:
    s = s.replace(old, new)
    p.write_text(s)
    print(f"::notice::{p} patched: -fPIC added to CMAKE_ASM_FLAGS on Android")
else:
    print(f"::warning::{p} ARM64 FFmpeg ASM block not found")
PY

# 12. Fallback: disable FFmpeg AArch64 NEON assembly on Android.
#
# Patch #11 attempted to pass -fPIC to ASM sources, but FFmpeg's
# hand-written NEON .S files use adrp/add absolute relocations
# (R_AARCH64_ADR_PREL_PG_HI21 / R_AARCH64_ADD_ABS_LO12_NC) that are
# inherently non-PIC and cannot be made PIC by a compile flag.  lld
# still rejects them when linking liblibavcodec.a into the shared
# librexruntime.so on Android.  Verified in run #17 (commit dc3f3a0)
# which still produced 42 errors of the form:
#   ld.lld: error: relocation R_AARCH64_ADR_PREL_PG_HI21 cannot be used
#   against symbol 'ff_cos_32'; recompile with -fPIC
#
# Per the user's instruction: as a last-resort Android-only fallback,
# drop the .S NEON sources from libavcodec and libavutil on Android.
# The C fallback implementations in FFmpeg (HAVE_NEON=0) take over.
# FFmpeg as a whole stays functional for XMA / WMA Pro decoding; only
# the NEON-tuned inner loops are replaced by their C equivalents.
#
# We do this by wrapping the two `if(IS_ARM64) target_sources(... .S ...)`
# blocks for libavutil and libavcodec in `if(IS_ARM64 AND NOT ANDROID)`.
python3 - "$THIRDPARTY_CMAKE" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
s = p.read_text()
if "REX_ANDROID_FFMPEG_NO_ASM" in s:
    print(f"::notice::{p} already has Android FFmpeg no-asm fallback")
else:
    # 12a. libavutil AArch64 NEON source block.
    old1 = """# ARM64 optimizations for libavutil
if(IS_ARM64)
    target_sources(libavutil PRIVATE
        ${FFMPEG_DIR}/libavutil/aarch64/cpu.c
        ${FFMPEG_DIR}/libavutil/aarch64/float_dsp_init.c
        ${FFMPEG_DIR}/libavutil/aarch64/float_dsp_neon.S
    )
    target_compile_definitions(libavutil PRIVATE
        HAVE_NEON=1
        HAVE_ARMV8=1
        HAVE_INLINE_ASM=1
    )
endif()"""
    new1 = """# ARM64 optimizations for libavutil
# REX_ANDROID_FFMPEG_NO_ASM: skip NEON .S on Android - hand-written
# adrp/add relocations are non-PIC and lld rejects them in shared links.
# float_dsp_init.c also has to be excluded because it declares extern
# prototypes for ff_vector_fmul_neon / ff_scalarproduct_float_neon / etc.
# and assigns them into the AVFloatDSPContext vtable inside
# `if (have_neon(cpu_flags))` - that path may be unreachable at runtime
# with HAVE_NEON=0, but the symbols are still referenced at link time,
# producing "undefined symbol: ff_*_neon" errors.
if(IS_ARM64 AND NOT ANDROID)
    target_sources(libavutil PRIVATE
        ${FFMPEG_DIR}/libavutil/aarch64/cpu.c
        ${FFMPEG_DIR}/libavutil/aarch64/float_dsp_init.c
        ${FFMPEG_DIR}/libavutil/aarch64/float_dsp_neon.S
    )
    target_compile_definitions(libavutil PRIVATE
        HAVE_NEON=1
        HAVE_ARMV8=1
        HAVE_INLINE_ASM=1
    )
elseif(ANDROID)
    # Android: keep only cpu.c (CPU flags detection, no NEON externs).
    # HAVE_NEON=0 + the absence of float_dsp_init.c makes FFmpeg's
    # avutil fall back to the generic C float_dsp implementation in
    # libavutil/float_dsp.c.
    target_sources(libavutil PRIVATE
        ${FFMPEG_DIR}/libavutil/aarch64/cpu.c
    )
    target_compile_definitions(libavutil PRIVATE
        HAVE_NEON=0
        HAVE_ARMV8=1
        HAVE_INLINE_ASM=0
    )
endif()"""
    # 12b. libavcodec AArch64 NEON source block.
    old2 = """# ARM64 optimizations for libavcodec
if(IS_ARM64)
    target_sources(libavcodec PRIVATE
        ${FFMPEG_DIR}/libavcodec/aarch64/fft_init_aarch64.c
        ${FFMPEG_DIR}/libavcodec/aarch64/fft_neon.S
        ${FFMPEG_DIR}/libavcodec/aarch64/mdct_neon.S
        ${FFMPEG_DIR}/libavcodec/aarch64/simple_idct_neon.S
        ${FFMPEG_DIR}/libavcodec/aarch64/videodsp.S
        ${FFMPEG_DIR}/libavcodec/aarch64/neon.S
        ${FFMPEG_DIR}/libavcodec/aarch64/mpegaudiodsp_init.c
        ${FFMPEG_DIR}/libavcodec/aarch64/mpegaudiodsp_neon.S
    )
    target_compile_definitions(libavcodec PRIVATE
        HAVE_NEON=1
        HAVE_ARMV8=1
        HAVE_INLINE_ASM=1
    )
endif()"""
    new2 = """# ARM64 optimizations for libavcodec
# REX_ANDROID_FFMPEG_NO_ASM: skip NEON .S on Android - hand-written
# adrp/add relocations are non-PIC and lld rejects them in shared links.
# The *_init_aarch64.c files register NEON dispatch at runtime; with the
# .S files excluded they become no-ops (HAVE_NEON=0 below makes FFmpeg's
# config dispatch fall back to the C implementations).
if(IS_ARM64 AND NOT ANDROID)
    target_sources(libavcodec PRIVATE
        ${FFMPEG_DIR}/libavcodec/aarch64/fft_init_aarch64.c
        ${FFMPEG_DIR}/libavcodec/aarch64/fft_neon.S
        ${FFMPEG_DIR}/libavcodec/aarch64/mdct_neon.S
        ${FFMPEG_DIR}/libavcodec/aarch64/simple_idct_neon.S
        ${FFMPEG_DIR}/libavcodec/aarch64/videodsp.S
        ${FFMPEG_DIR}/libavcodec/aarch64/neon.S
        ${FFMPEG_DIR}/libavcodec/aarch64/mpegaudiodsp_init.c
        ${FFMPEG_DIR}/libavcodec/aarch64/mpegaudiodsp_neon.S
    )
    target_compile_definitions(libavcodec PRIVATE
        HAVE_NEON=1
        HAVE_ARMV8=1
        HAVE_INLINE_ASM=1
    )
elseif(ANDROID)
    # Android: skip ALL aarch64-specific codec sources (the .S NEON
    # assembly plus the *_init_aarch64.c dispatch shims).  Both
    # fft_init_aarch64.c and mpegaudiodsp_init.c declare extern NEON
    # symbols and assign them to codec context vtables - including
    # them without the .S files produces "undefined symbol: ff_*_neon"
    # link errors (verified in run #19, commit 7eb57fd).
    #
    # With none of these sources compiled, libavcodec falls back to
    # the generic C implementations in libavcodec/fft_template.c,
    # libavcodec/mpegaudiodsp.c, etc.
    target_compile_definitions(libavcodec PRIVATE
        HAVE_NEON=0
        HAVE_ARMV8=1
        HAVE_INLINE_ASM=0
    )
endif()"""
    changed = False
    if old1 in s:
        s = s.replace(old1, new1)
        changed = True
    if old2 in s:
        s = s.replace(old2, new2)
        changed = True
    if changed:
        p.write_text(s)
        print(f"::notice::{p} patched: FFmpeg AArch64 NEON .S excluded on Android (REX_ANDROID_FFMPEG_NO_ASM)")
    else:
        print(f"::warning::{p} could not find libavutil/libavcodec ARM64 source blocks")
PY

# 13. Patch include/rex/thread/fiber.h so the Android build of the
#     Fiber struct does not depend on <ucontext.h> (which is shipped by
#     the NDK with incompatible sigcontext-based typedefs).  The Android
#     branch declares an empty struct layout; the implementation lives
#     in fiber_android.cpp (also added by this patch script via a file
#     write to src/core/).  At runtime the stub returns nullptr/false
#     from all four member functions, so the empty layout is fine.
FIBER_H="$SDK_DIR/include/rex/thread/fiber.h"
python3 - "$FIBER_H" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
s = p.read_text()
if "REX_PLATFORM_ANDROID" in s:
    print(f"::notice::{p} already has Android branch")
else:
    old = """#if REX_PLATFORM_LINUX
#include <ucontext.h>
#include <cstdint>
#include <vector>
#elif REX_PLATFORM_MAC
#include <cstdint>
#include <vector>
#endif"""
    new = """#if REX_PLATFORM_ANDROID
// STUB Android: Fiber is non-functional (no ucontext.h).  The struct
// layout is intentionally empty - fiber_android.cpp returns nullptr /
// no-ops from every member function, so no fields are needed.
#include <cstdint>
#elif REX_PLATFORM_LINUX
#include <ucontext.h>
#include <cstdint>
#include <vector>
#elif REX_PLATFORM_MAC
#include <cstdint>
#include <vector>
#endif"""
    if old in s:
        s = s.replace(old, new)
        p.write_text(s)
        print(f"::notice::{p} patched: added Android branch (no ucontext.h)")
    else:
        print(f"::warning::{p} platform-include block not found")

# Also wrap the Linux data members so they only appear on non-Android Linux.
old2 = """#if REX_PLATFORM_WIN32
  void* handle_ = nullptr;
  bool is_thread_fiber_ = false;
#elif REX_PLATFORM_LINUX
  ucontext_t context_{};
  std::vector<uint8_t> stack_;
  void (*entry_)(void*) = nullptr;
  void* arg_ = nullptr;
  bool is_thread_fiber_ = false;

  static void Trampoline();
#elif REX_PLATFORM_MAC
  void* context_ = nullptr;
  std::vector<uint8_t> stack_;
  void (*entry_)(void*) = nullptr;
  void* arg_ = nullptr;
  bool is_thread_fiber_ = false;

  static void Trampoline();
#endif"""
new2 = """#if REX_PLATFORM_WIN32
  void* handle_ = nullptr;
  bool is_thread_fiber_ = false;
#elif REX_PLATFORM_ANDROID
  // STUB Android: no data members - all Fiber ops are no-ops.
#elif REX_PLATFORM_LINUX
  ucontext_t context_{};
  std::vector<uint8_t> stack_;
  void (*entry_)(void*) = nullptr;
  void* arg_ = nullptr;
  bool is_thread_fiber_ = false;

  static void Trampoline();
#elif REX_PLATFORM_MAC
  void* context_ = nullptr;
  std::vector<uint8_t> stack_;
  void (*entry_)(void*) = nullptr;
  void* arg_ = nullptr;
  bool is_thread_fiber_ = false;

  static void Trampoline();
#endif"""
if "REX_PLATFORM_ANDROID\n  // STUB Android: no data members" in s:
    pass  # already done
elif old2 in s:
    s = s.replace(old2, new2)
    p.write_text(s)
    print(f"::notice::{p} patched: Android branch has no data members")
else:
    print(f"::warning::{p} data-member block not found")
PY

# 14. Add fiber_android.cpp to rexcore on Android.  Already added
#     src/core/fiber_android.cpp via Write tool earlier in this patch
#     script's lifetime - just make sure the CMakeLists.txt includes it.
python3 - "$CORE_CMAKE" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
s = p.read_text()
if "fiber_android.cpp" in s:
    print(f"::notice::{p} already lists fiber_android.cpp")
else:
    # Insert into the elseif(ANDROID) target_sources block added by patch #6.
    anchor = """elseif(ANDROID)
    # REX_ANDROID_CORE_POSIX_SOURCES: reduced POSIX source set for Android.
    # - fiber_posix.cpp excluded: <ucontext.h> not in NDK, conflicts with
    #   sys/ucontext.h's typedefs.
    # - exception_handler_posix.cpp excluded: uses x86_64-only REG_RIP /
    #   REG_RAX / ... which don't exist on arm64.
    target_sources(rexcore PRIVATE
        atomic_posix.cpp"""
    addition = """elseif(ANDROID)
    # REX_ANDROID_CORE_POSIX_SOURCES: reduced POSIX source set for Android.
    # - fiber_posix.cpp excluded: <ucontext.h> not in NDK, conflicts with
    #   sys/ucontext.h's typedefs.
    # - exception_handler_posix.cpp excluded: uses x86_64-only REG_RIP /
    #   REG_RAX / ... which don't exist on arm64.
    target_sources(rexcore PRIVATE
        fiber_android.cpp
        exception_handler_android.cpp
        filesystem_android.cpp
        atomic_posix.cpp"""
    if anchor in s:
        s = s.replace(anchor, addition)
        p.write_text(s)
        print(f"::notice::{p} patched: fiber_android.cpp + exception_handler_android.cpp added to Android sources")
    else:
        print(f"::warning::{p} Android target_sources block not found")
PY

# 15. Add thirdparty/FFmpeg/android_stubs.c to libavcodec on Android
#     so the three undefined AArch64 dispatcher entry points
#     (ff_float_dsp_init_aarch64, ff_fft_init_aarch64, ff_mpadsp_init_aarch64)
#     resolve at link time.  See the file's header comment for why this
#     is needed even after patches #11 and #12 excluded the .S and
#     *_init_aarch64.c sources from the Android build.
python3 - "$THIRDPARTY_CMAKE" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
s = p.read_text()
if "FFmpeg/android_stubs.c" in s:
    print(f"::notice::{p} already lists FFmpeg/android_stubs.c")
else:
    # Append after the libavcodec block (look for the elseif(ANDROID)
    # branch added by patch #12).
    anchor = """elseif(ANDROID)
    # Android: skip ALL aarch64-specific codec sources (the .S NEON
    # assembly plus the *_init_aarch64.c dispatch shims).  Both
    # fft_init_aarch64.c and mpegaudiodsp_init.c declare extern NEON
    # symbols and assign them to codec context vtables - including
    # them without the .S files produces "undefined symbol: ff_*_neon"
    # link errors (verified in run #19, commit 7eb57fd).
    #
    # With none of these sources compiled, libavcodec falls back to
    # the generic C implementations in libavcodec/fft_template.c,
    # libavcodec/mpegaudiodsp.c, etc.
    target_compile_definitions(libavcodec PRIVATE
        HAVE_NEON=0
        HAVE_ARMV8=1
        HAVE_INLINE_ASM=0
    )
endif()"""
    addition = anchor.replace(
        "    )\nendif()",
        "    )\n    # Provide no-op stubs for the three AArch64 dispatcher entry\n    # points that the generic FFmpeg sources still call under\n    # `if (ARCH_AARCH64)` (which is hard-defined to 1 in\n    # config_android_aarch64.h).  Without these stubs the link of\n    # librexruntime.so fails with:\n    #   undefined symbol: ff_float_dsp_init_aarch64\n    #   undefined symbol: ff_fft_init_aarch64\n    #   undefined symbol: ff_mpadsp_init_aarch64\n    target_sources(libavcodec PRIVATE\n        ${FFMPEG_DIR}/android_stubs.c\n    )\nendif()"
    )
    if anchor in s:
        s = s.replace(anchor, addition)
        p.write_text(s)
        print(f"::notice::{p} patched: FFmpeg/android_stubs.c added to libavcodec on Android")
    else:
        print(f"::warning::{p} libavcodec ANDROID block not found")
PY

# 16. Generate src/core/fiber_android.cpp (STUB Android Fiber impl).
FIBER_ANDROID_CPP="$SDK_DIR/src/core/fiber_android.cpp"
cat > "$FIBER_ANDROID_CPP" <<'CPP'
// SPDX-License-Identifier: BSD-3-Clause
//
// STUB Android: rex::thread::Fiber — non-functional on Android.
//
// The full Fiber implementation in fiber_posix.cpp depends on ucontext.h
// (getcontext/makecontext/swapcontext), which the Android NDK does not
// ship with usable typedefs (sys/ucontext.h declares mcontext_t /
// ucontext_t as sigcontext-based, incompatible with the host-side fiber
// layout the SDK expects).
//
// This stub provides the four member functions referenced by the
// rexruntime call sites (xthread.cpp, kernel/crt/threading.cpp) so the
// shared library links cleanly on Android.  At runtime, any attempt to
// create or switch fibers will log an error and return nullptr/false —
// the recomp runtime cannot actually run PPC guest code without fibers,
// but the stub lets the APK install and the SDL window open so we can
// validate the rest of the port pipeline.
//
// Before shipping a playable Android build, this file MUST be replaced
// with a real implementation (e.g. vendoring libucontext, or rewriting
// Fiber on top of pthread + sigaltstack + makecontext-like trampolines).

#include <rex/platform.h>
#include <rex/thread/fiber.h>

#include <cstddef>
#include <cstdio>

namespace rex::thread {

// Definition of the thread-local current-fiber pointer declared in fiber.h.
// Always nullptr on Android since we never create real fibers.
thread_local Fiber* Fiber::tls_current_ = nullptr;

Fiber* Fiber::ConvertCurrentThread() {
  // STUB Android: cannot convert thread to fiber without ucontext.
  std::fprintf(stderr,
               "[skate3recomp] STUB: Fiber::ConvertCurrentThread() "
               "called on Android - fibers not implemented\n");
  return nullptr;
}

Fiber* Fiber::Create(size_t /*stack_size*/, void (*/*entry*/)(void*),
                     void* /*arg*/) {
  // STUB Android: cannot create fiber without ucontext.
  std::fprintf(stderr,
               "[skate3recomp] STUB: Fiber::Create() called on Android - "
               "fibers not implemented\n");
  return nullptr;
}

void Fiber::SwitchTo(Fiber* /*target*/) {
  // STUB Android: cannot switch fibers without ucontext.  No-op is safe
  // because Create() returns nullptr - callers must not invoke SwitchTo
  // with a non-null target if Create failed.
  std::fprintf(stderr,
               "[skate3recomp] STUB: Fiber::SwitchTo() called on Android - "
               "fibers not implemented\n");
}

void Fiber::Destroy() {
  // STUB Android: nothing to free; Fiber objects are never constructed
  // because Create() and ConvertCurrentThread() both return nullptr.
}

}  // namespace rex::thread
CPP
echo "::notice::$FIBER_ANDROID_CPP written (Fiber stub)"

# 17. Generate src/core/exception_handler_android.cpp (STUB Android
#     ExceptionHandler impl).
EXC_ANDROID_CPP="$SDK_DIR/src/core/exception_handler_android.cpp"
cat > "$EXC_ANDROID_CPP" <<'CPP'
// SPDX-License-Identifier: BSD-3-Clause
//
// STUB Android: rex::arch::ExceptionHandler — crash recovery disabled.
//
// The full implementation in exception_handler_posix.cpp depends on
// SIGSEGV/SIGBUS signal handlers and x86_64-only register macros
// (REG_RIP, REG_RAX, ... in mcontext_t) that don't exist on arm64.  A
// proper Android port would need to walk arm64's sigcontext to extract
// PC, SP, X0..X30, etc., and is out of scope for the current "make CI
// green" stub phase.
//
// This stub provides no-op Install / Uninstall so the shared library
// links cleanly.  At runtime, MMIOHandler and any code that relies on
// ExceptionHandler will not receive crash callbacks — they will get
// the OS default behaviour (SIGSEGV → process termination) instead of
// recovering.  This is acceptable for the current stub build because
// the recomp runtime cannot actually run PPC guest code without fibers
// (see fiber_android.cpp).
//
// Before shipping a playable Android build, this file MUST be replaced
// with a real implementation based on arm64 sigaction / sigcontext.

#include <rex/exception_handler.h>

namespace rex::arch {

void ExceptionHandler::Install(Handler /*fn*/, void* /*data*/) {
  // STUB Android: crash recovery not implemented.
}

void ExceptionHandler::Uninstall(Handler /*fn*/, void* /*data*/) {
  // STUB Android: symmetric no-op for Install above.
}

}  // namespace rex::arch
CPP
echo "::notice::$EXC_ANDROID_CPP written (ExceptionHandler stub)"

# 18. Generate src/core/filesystem_android.cpp (REAL Android filesystem
#     content-URI helpers using SAF + JNI).
FS_ANDROID_CPP="$SDK_DIR/src/core/filesystem_android.cpp"
cat > "$FS_ANDROID_CPP" <<'CPP'
// SPDX-License-Identifier: BSD-3-Clause
//
// Android: rex::filesystem content-URI helpers — real implementation.
//
// Implements the three Android-only entry points declared in
// include/rex/filesystem.h:
//
//   bool IsAndroidContentUri(const std::string_view source);
//   int  OpenAndroidContentFileDescriptor(const std::string_view uri,
//                                          const char* mode);
//
// Uses JNI to call into Java:
//   - IsAndroidContentUri: pure C++ prefix check on "content://".
//   - OpenAndroidContentFileDescriptor: calls
//     ContentResolver.openFileDescriptor(uri, mode) on the Java side,
//     then ParcelFileDescriptor.detachFd() to take ownership of the
//     file descriptor.
//
// The file picker itself (ACTION_OPEN_DOCUMENT) is implemented in
// SDLActivity.java::pickFileWithSAF(), and called from
// skate3_iso_installer.cpp / skate3_title_update_installer.cpp via
// the same JNI bridge.

#include <rex/platform.h>

#if REX_PLATFORM_ANDROID

#include <rex/filesystem.h>

#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <future>
#include <memory>
#include <string>
#include <string_view>

#include <jni.h>
#include <android/log.h>

// Forward-declare SDL3's Android JNI accessor so we don't need to pull
// in SDL_system.h here.  The actual symbol is provided by the vendored
// libSDL3.a at link time.  (SDL2 has SDL_GetJavaVM() that returns a
// JavaVM*; SDL3 changed this to SDL_GetAndroidJNIEnv() returning a
// JNIEnv* directly, which is even simpler for our use case.)
extern "C" {
void* SDL_GetAndroidJNIEnv(void);
}

#define TAG "skate3-fs"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN,  TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

namespace rex::filesystem {

bool IsAndroidContentUri(std::string_view source) {
  // Cheap prefix check, no JNI needed.
  constexpr std::string_view kPrefix = "content://";
  return source.size() >= kPrefix.size()
         && source.substr(0, kPrefix.size()) == kPrefix;
}

// ---------------------------------------------------------------------------
// JNI helper: get the JNIEnv for the current thread, attaching if needed.
// Returns nullptr if the JVM could not be obtained or the thread could
// not be attached.  When attached successfully, the caller MUST call
// DetachCurrentThread before returning (we use a RAII guard).
//
// We obtain the JavaVM* once from SDL_GetAndroidJNIEnv() (which returns
// the JNIEnv* of SDL's main thread), then use JavaVM->GetEnv /
// AttachCurrentThread on each calling thread.  This works because all
// JNIEnv*s from the same JavaVM share the same JVM.
// ---------------------------------------------------------------------------
namespace {

struct JNIEnvGuard {
  JavaVM* vm = nullptr;
  JNIEnv* env = nullptr;
  bool attached = false;

  explicit JNIEnvGuard(JavaVM* jvm) : vm(jvm) {
    if (!vm) return;
    jint rc = vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6);
    if (rc == JNI_EDETACHED) {
      rc = vm->AttachCurrentThread(&env, nullptr);
      attached = (rc == JNI_OK);
    }
  }
  ~JNIEnvGuard() {
    if (attached && vm) {
      vm->DetachCurrentThread();
    }
  }
};

JavaVM* GetJavaVM() {
  // SDL3 provides SDL_GetAndroidJNIEnv() which returns the JNIEnv* of
  // SDL's main thread.  We extract the JavaVM* from it once; this is
  // safe because all JNIEnv*s from the same JavaVM share the same JVM.
  JNIEnv* mainEnv = reinterpret_cast<JNIEnv*>(SDL_GetAndroidJNIEnv());
  if (!mainEnv) {
    return nullptr;
  }
  JavaVM* vm = nullptr;
  jint rc = mainEnv->GetJavaVM(&vm);
  if (rc != JNI_OK) {
    return nullptr;
  }
  return vm;
}

}  // namespace

int OpenAndroidContentFileDescriptor(std::string_view uri,
                                      const char* mode) {
  if (!IsAndroidContentUri(uri)) {
    errno = EINVAL;
    return -1;
  }
  if (!mode) {
    errno = EINVAL;
    return -1;
  }

  JavaVM* vm = GetJavaVM();
  if (!vm) {
    LOGE("OpenAndroidContentFileDescriptor: no JavaVM available");
    errno = ENOSYS;
    return -1;
  }

  JNIEnvGuard g(vm);
  if (!g.env) {
    LOGE("OpenAndroidContentFileDescriptor: failed to attach JNIEnv");
    errno = ENOSYS;
    return -1;
  }

  // Translate C "r"/"rw"/"rwt" to Java mode "r"/"rw"/"rwt".
  // (ContentResolver.openFileDescriptor accepts "r", "w", "wt", "wa",
  // "rw", "rwt".)
  std::string jmode(mode);
  JNIEnv* env = g.env;

  // Find SDLActivity class (note: SDLActivity is in org.libsdl.app).
  jclass sdlActivityClass = env->FindClass("org/libsdl/app/SDLActivity");
  if (!sdlActivityClass) {
    LOGE("OpenAndroidContentFileDescriptor: SDLActivity class not found");
    env->ExceptionClear();
    errno = ENOSYS;
    return -1;
  }

  // Get the mSingleton static field (this is the running SDLActivity).
  jfieldID singletonField = env->GetStaticFieldID(
      sdlActivityClass, "mSingleton", "Lorg/libsdl/app/SDLActivity;");
  if (!singletonField) {
    LOGE("OpenAndroidContentFileDescriptor: mSingleton field not found");
    env->ExceptionClear();
    errno = ENOSYS;
    return -1;
  }
  jobject activity = env->GetStaticObjectField(sdlActivityClass, singletonField);
  if (!activity) {
    LOGE("OpenAndroidContentFileDescriptor: SDLActivity.mSingleton is null");
    errno = ENOSYS;
    return -1;
  }

  // Call activity.getContentResolver()
  jmethodID getContentResolver = env->GetMethodID(
      env->GetObjectClass(activity), "getContentResolver",
      "()Landroid/content/ContentResolver;");
  if (!getContentResolver) {
    LOGE("OpenAndroidContentFileDescriptor: getContentResolver() not found");
    env->ExceptionClear();
    errno = ENOSYS;
    return -1;
  }
  jobject contentResolver = env->CallObjectMethod(activity, getContentResolver);
  if (env->ExceptionCheck()) {
    env->ExceptionDescribe();
    env->ExceptionClear();
    errno = EIO;
    return -1;
  }
  if (!contentResolver) {
    LOGE("OpenAndroidContentFileDescriptor: getContentResolver() returned null");
    errno = EIO;
    return -1;
  }

  // Build the Java Uri from the string.
  jclass uriClass = env->FindClass("android/net/Uri");
  if (!uriClass) {
    LOGE("OpenAndroidContentFileDescriptor: android.net.Uri class not found");
    env->ExceptionClear();
    errno = ENOSYS;
    return -1;
  }
  jmethodID uriParse = env->GetStaticMethodID(
      uriClass, "parse", "(Ljava/lang/String;)Landroid/net/Uri;");
  if (!uriParse) {
    LOGE("OpenAndroidContentFileDescriptor: Uri.parse() not found");
    env->ExceptionClear();
    errno = ENOSYS;
    return -1;
  }
  std::string uriStr(uri);
  jstring juriStr = env->NewStringUTF(uriStr.c_str());
  jobject uriObj = env->CallStaticObjectMethod(uriClass, uriParse, juriStr);
  env->DeleteLocalRef(juriStr);
  if (env->ExceptionCheck() || !uriObj) {
    env->ExceptionDescribe();
    env->ExceptionClear();
    LOGE("OpenAndroidContentFileDescriptor: Uri.parse(\"%s\") failed", uriStr.c_str());
    errno = EINVAL;
    return -1;
  }

  // Call ContentResolver.openFileDescriptor(uri, mode).
  // openFileDescriptor returns a ParcelFileDescriptor; on failure it
  // throws FileNotFoundException.
  jclass contentResolverClass = env->GetObjectClass(contentResolver);
  jmethodID openFd = env->GetMethodID(
      contentResolverClass, "openFileDescriptor",
      "(Landroid/net/Uri;Ljava/lang/String;)Landroid/os/ParcelFileDescriptor;");
  if (!openFd) {
    LOGE("OpenAndroidContentFileDescriptor: openFileDescriptor() not found");
    env->ExceptionClear();
    errno = ENOSYS;
    return -1;
  }
  jstring jmodeStr = env->NewStringUTF(jmode.c_str());
  jobject pfd = env->CallObjectMethod(contentResolver, openFd, uriObj, jmodeStr);
  env->DeleteLocalRef(jmodeStr);
  if (env->ExceptionCheck()) {
    env->ExceptionDescribe();
    env->ExceptionClear();
    LOGE("OpenAndroidContentFileDescriptor: openFileDescriptor(\"%s\",\"%s\") threw",
         uriStr.c_str(), jmode.c_str());
    errno = ENOENT;
    return -1;
  }
  if (!pfd) {
    LOGE("OpenAndroidContentFileDescriptor: openFileDescriptor returned null");
    errno = ENOENT;
    return -1;
  }

  // Call pfd.detachFd() to take ownership of the FD.
  jmethodID detachFd = env->GetMethodID(
      env->GetObjectClass(pfd), "detachFd", "()I");
  if (!detachFd) {
    LOGE("OpenAndroidContentFileDescriptor: detachFd() not found");
    env->ExceptionClear();
    env->DeleteLocalRef(pfd);
    errno = ENOSYS;
    return -1;
  }
  jint fd = env->CallIntMethod(pfd, detachFd);
  if (env->ExceptionCheck()) {
    env->ExceptionDescribe();
    env->ExceptionClear();
    env->DeleteLocalRef(pfd);
    errno = EIO;
    return -1;
  }
  env->DeleteLocalRef(pfd);

  LOGI("OpenAndroidContentFileDescriptor(\"%s\", \"%s\") = fd %d",
       uriStr.c_str(), jmode.c_str(), (int)fd);
  return (int)fd;
}

// ---------------------------------------------------------------------------
// SAF file picker: called by skate3_iso_installer.cpp /
// skate3_title_update_installer.cpp to launch the system file picker
// and block (with timeout) until the user picks a file or cancels.
// Returns the content:// URI as a std::string, or "" on cancel/timeout.
//
// Implementation notes:
//   - The Java side (SDLActivity.pickFileWithSAF) is synchronous from
//     the JNI caller's perspective: it blocks on a monitor until
//     onActivityResult fires.
//   - We wrap the JNI call in std::async + wait_for(5min) so the
//     native caller doesn't hang forever if the picker never returns
//     (e.g. user switched apps, system killed the picker activity).
//   - JNIEnv pointers are thread-local; the worker thread must attach
//     its own JNIEnv via AttachCurrentThread.
// ---------------------------------------------------------------------------
std::string PickFileWithSAF(const char* mime_type_filter,
                             const char* extension_filters,
                             const char* dialog_title) {
  JavaVM* vm = GetJavaVM();
  if (!vm) {
    LOGE("PickFileWithSAF: no JavaVM available");
    return "";
  }

  std::string mime = mime_type_filter ? mime_type_filter : "*/*";
  std::string ext  = extension_filters ? extension_filters : "";
  std::string title = dialog_title ? dialog_title : "";

  // Spawn a worker thread that attaches its own JNIEnv, calls the Java
  // pickFileWithSAF method, and returns the result via std::future.
  std::future<std::string> future = std::async(
      std::launch::async,
      [vm, mime, ext, title]() -> std::string {
        JNIEnvGuard g(vm);
        if (!g.env) {
          LOGE("PickFileWithSAF worker: failed to attach JNIEnv");
          return "";
        }
        JNIEnv* env = g.env;

        jclass sdlActivityClass = env->FindClass("org/libsdl/app/SDLActivity");
        if (!sdlActivityClass) {
          LOGE("PickFileWithSAF: SDLActivity class not found");
          env->ExceptionClear();
          return "";
        }

        jmethodID pickMethod = env->GetStaticMethodID(
            sdlActivityClass, "pickFileWithSAF",
            "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;");
        if (!pickMethod) {
          LOGE("PickFileWithSAF: pickFileWithSAF method not found");
          env->ExceptionClear();
          return "";
        }

        jstring jMime = env->NewStringUTF(mime.c_str());
        jstring jExt = env->NewStringUTF(ext.c_str());
        jstring jTitle = env->NewStringUTF(title.c_str());

        jstring jResult = static_cast<jstring>(
            env->CallStaticObjectMethod(sdlActivityClass, pickMethod,
                                         jMime, jExt, jTitle));
        env->DeleteLocalRef(jMime);
        env->DeleteLocalRef(jExt);
        env->DeleteLocalRef(jTitle);

        if (env->ExceptionCheck()) {
          env->ExceptionDescribe();
          env->ExceptionClear();
          return "";
        }
        if (!jResult) {
          return "";
        }

        const char* chars = env->GetStringUTFChars(jResult, nullptr);
        std::string result = chars ? chars : "";
        if (chars) {
          env->ReleaseStringUTFChars(jResult, chars);
        }
        env->DeleteLocalRef(jResult);
        return result;
      });

  // Wait up to 5 minutes for the picker to complete.
  if (future.wait_for(std::chrono::minutes(5)) == std::future_status::timeout) {
    LOGW("PickFileWithSAF: 5-minute timeout expired, returning empty path. "
         "The picker UI may still be open - the user can dismiss it manually.");
    // The std::async future's destructor will block on the worker thread
    // when `future` goes out of scope.  We can't cancel the JNI call,
    // but the worker will eventually finish (when the user dismisses the
    // picker or the system kills it).  Returning empty path lets the
    // caller fall through to the ImGui wizard fallback.
    return "";
  }

  return future.get();
}

}  // namespace rex::filesystem

#endif  // REX_PLATFORM_ANDROID
CPP
echo "::notice::$FS_ANDROID_CPP written (filesystem REAL impl with SAF + JNI)"

# 19. Generate thirdparty/FFmpeg/android_stubs.c (STUB Android FFmpeg
#     AArch64 dispatcher entry points).
FFMPEG_STUBS_C="$SDK_DIR/thirdparty/FFmpeg/android_stubs.c"
cat > "$FFMPEG_STUBS_C" <<'C'
// SPDX-License-Identifier: BSD-3-Clause
//
// STUB Android: FFmpeg AArch64 dispatcher entry points.
//
// The vendored FFmpeg ships AArch64 NEON-optimized inner loops in
// libavcodec/aarch64/*.S and libavutil/aarch64/*.S, plus C dispatcher
// shims (*_init_aarch64.c) that register NEON function pointers into
// codec/util context vtables.  The rexglue-sdk build excludes both
// from the Android target (see .github/scripts/patch-rexglue-android.sh
// patch #12) because:
//
//   1. The .S files use hand-written adrp/add relocations that are
//      non-PIC and cause lld to fail with R_AARCH64_ADR_PREL_PG_HI21
//      when linking liblibavcodec.a into the shared librexruntime.so.
//
//   2. The *_init_aarch64.c shims declare extern NEON prototypes that
//      become "undefined symbol" link errors when the .S files are
//      excluded.
//
// However, the generic FFmpeg sources (fft_template.c, mpegaudiodsp.c,
// float_dsp.c) still call ff_fft_init_aarch64() / ff_mpadsp_init_aarch64()
// / ff_float_dsp_init_aarch64() inside `if (ARCH_AARCH64)` blocks, and
// ARCH_AARCH64 is hard-defined to 1 in thirdparty/FFmpeg/config_android_aarch64.h.
//
// This file provides no-op implementations of those three dispatcher
// entry points so the link succeeds.  At runtime:
//   - The vtable slots in AVFloatDSPContext / FFTContext / MPADSPContext
//     remain populated with the generic C fallbacks that FFmpeg's own
//     _init() functions (ff_float_dsp_init, ff_fft_init, ff_mpdsp_init)
//     already set before calling the aarch64 hook.
//   - So audio decoding still works, just without NEON acceleration.
//
// Before shipping a playable Android build that needs NEON-accelerated
// audio decode, this file MUST be replaced with real implementations.

#include "libavutil/float_dsp.h"
#include "libavcodec/fft.h"
#include "libavcodec/mpegaudiodsp.h"

// From libavutil/float_dsp.h: void ff_float_dsp_init_aarch64(AVFloatDSPContext *fdsp);
void ff_float_dsp_init_aarch64(AVFloatDSPContext *fdsp) {
  // STUB Android: no NEON dispatchers to register.
  (void)fdsp;
}

// From libavcodec/fft.h: void ff_fft_init_aarch64(FFTContext *s);
void ff_fft_init_aarch64(FFTContext *s) {
  // STUB Android: no NEON dispatchers to register.
  (void)s;
}

// From libavcodec/mpegaudiodsp.h: void ff_mpadsp_init_aarch64(MPADSPContext *s);
void ff_mpadsp_init_aarch64(MPADSPContext *s) {
  // STUB Android: no NEON dispatchers to register.
  (void)s;
}
C
echo "::notice::$FFMPEG_STUBS_C written (FFmpeg AArch64 dispatcher stubs)"

# 20. Patch include/rex/filesystem.h to declare the new PickFileWithSAF
#     entry point so skate3_iso_installer.cpp and
#     skate3_title_update_installer.cpp can call it.
FS_H="$SDK_DIR/include/rex/filesystem.h"
python3 - "$FS_H" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
s = p.read_text()
if "PickFileWithSAF" in s:
    print(f"::notice::{p} already declares PickFileWithSAF")
else:
    old = """#if REX_PLATFORM_ANDROID
void AndroidInitialize();
void AndroidShutdown();
bool IsAndroidContentUri(const std::string_view source);
int OpenAndroidContentFileDescriptor(const std::string_view uri, const char* mode);
#endif  // REX_PLATFORM_ANDROID"""
    new = """#if REX_PLATFORM_ANDROID
void AndroidInitialize();
void AndroidShutdown();
bool IsAndroidContentUri(const std::string_view source);
int OpenAndroidContentFileDescriptor(const std::string_view uri, const char* mode);

// Opens Android's Storage Access Framework file picker (ACTION_OPEN_DOCUMENT)
// and blocks (with a 5-minute safety timeout) until the user selects a file
// or cancels.  Returns the selected file's content:// URI as a std::string,
// or an empty string if the user cancelled or the picker timed out.
//
// mimeTypeFilter:   MIME type to filter by (e.g. "application/octet-stream"
//                   for any binary file).  Pass "*/*" for no filter.
// extensionFilters: comma-separated extensions (e.g. ".iso,.ISO") - used
//                   only for the dialog title since ACTION_OPEN_DOCUMENT
//                   cannot filter by extension directly.
// dialogTitle:      title to display in the picker.
std::string PickFileWithSAF(const char* mime_type_filter,
                             const char* extension_filters,
                             const char* dialog_title);
#endif  // REX_PLATFORM_ANDROID"""
    if old in s:
        s = s.replace(old, new)
        p.write_text(s)
        print(f"::notice::{p} patched: added PickFileWithSAF declaration")
    else:
        print(f"::warning::{p} Android filesystem block not found")
PY

# 21. Patch src/ui/rex_app.cpp to skip <gnu/libc-version.h> on Android.
#     The header is GLIBC-specific and is not shipped by the Android NDK
#     (Bionic libc doesn't have gnu_get_libc_version()).  Both the
#     #include and the REXLOG_INFO call that uses it need to be guarded
#     with #if !defined(__ANDROID__) so the file compiles on Android.
#     On Android we log "Bionic" instead of the GLIBC version.
REX_APP_CPP="$SDK_DIR/src/ui/rex_app.cpp"
python3 - "$REX_APP_CPP" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
s = p.read_text()
if "REX_ANDROID_NO_GLIBC_VERSION" in s:
    print(f"::notice::{p} already patched for gnu/libc-version.h")
else:
    # 21a. Guard the #include <gnu/libc-version.h> block.
    old_inc = """#if REX_PLATFORM_LINUX
#include <gnu/libc-version.h>
#include <sys/utsname.h>
#endif"""
    new_inc = """#if REX_PLATFORM_LINUX
#include <sys/utsname.h>
#if !defined(__ANDROID__)
// REX_ANDROID_NO_GLIBC_VERSION: <gnu/libc-version.h> is GLIBC-specific
// and not shipped by the Android NDK (Bionic has no gnu_get_libc_version).
#include <gnu/libc-version.h>
#endif
#endif"""
    # 21b. Guard the gnu_get_libc_version() call.
    old_call = '  REXLOG_INFO("  glibc: {}", gnu_get_libc_version());'
    new_call = """#if defined(__ANDROID__)
  REXLOG_INFO("  libc: Bionic");
#else
  REXLOG_INFO("  glibc: {}", gnu_get_libc_version());
#endif"""
    changed = False
    if old_inc in s:
        s = s.replace(old_inc, new_inc)
        changed = True
    if old_call in s:
        s = s.replace(old_call, new_call)
        changed = True
    if changed:
        p.write_text(s)
        print(f"::notice::{p} patched: gnu/libc-version.h guarded on Android")
    else:
        print(f"::warning::{p} gnu/libc-version.h block not found")
PY

# 22. Patch include/rex/ui/windowed_app.h to NOT force
#     XE_UI_WINDOWED_APPS_IN_LIBRARY=1 on Android.  The forced value
#     makes REX_DEFINE_APP register the Creator in a static map (the
#     "multiple apps in one library" path), but windowed_app_main_sdl.cpp
#     calls GetWindowedAppCreator() which only exists in the
#     IN_LIBRARY=0 path.  Removing the forced #define lets the default
#     (0, "separate executables" path) take effect, which is correct for
#     the skate3 standalone app.
WINDOWED_APP_H="$SDK_DIR/include/rex/ui/windowed_app.h"
python3 - "$WINDOWED_APP_H" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
s = p.read_text()
old = """#if REX_PLATFORM_ANDROID
// Multiple apps in a single library instead of separate executables.
#define XE_UI_WINDOWED_APPS_IN_LIBRARY 1
#endif"""
if "REX_ANDROID_NO_FORCED_IN_LIBRARY" in s:
    print(f"::notice::{p} already patched (XE_UI_WINDOWED_APPS_IN_LIBRARY not forced on Android)")
elif old in s:
    new = """// REX_ANDROID_NO_FORCED_IN_LIBRARY: do NOT force
// XE_UI_WINDOWED_APPS_IN_LIBRARY=1 on Android.  The forced value breaks
// the standalone-app path (GetWindowedAppCreator free function) that
// windowed_app_main_sdl.cpp depends on.  Android uses the default (0),
// same as Linux/macOS desktop builds, so REX_DEFINE_APP generates the
// free function as expected."""
    s = s.replace(old, new)
    p.write_text(s)
    print(f"::notice::{p} patched: XE_UI_WINDOWED_APPS_IN_LIBRARY no longer forced on Android")
else:
    print(f"::warning::{p} Android IN_LIBRARY block not found")
PY

# 23. Patch src/ui/windowed_app_main_sdl.cpp to use SDL_main as the
#     entry point on Android.  SDL2 on Android invokes SDL_main (via
#     SDLActivity's JNI bridge), not the standard C main().  Without
#     this rename, the entry point is never called and the app silently
#     fails to start.
WINDOWED_APP_MAIN_SDL="$SDK_DIR/src/ui/windowed_app_main_sdl.cpp"
python3 - "$WINDOWED_APP_MAIN_SDL" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
s = p.read_text()
if "REX_ANDROID_SDL_MAIN" in s:
    print(f"::notice::{p} already patched for SDL_main")
else:
    old = "int main(int argc, char** argv) {"
    new = """#if defined(__ANDROID__)
// REX_ANDROID_SDL_MAIN: SDL2 on Android invokes SDL_main (via
// SDLActivity's JNI bridge), not the standard C main().  Without this
// rename the entry point is never called and the app silently fails.
extern \"C\" int SDL_main(int argc, char** argv)
#else
int main(int argc, char** argv)
#endif
{"""
    if old in s:
        s = s.replace(old, new)
        p.write_text(s)
        print(f"::notice::{p} patched: main -> SDL_main on Android")
    else:
        print(f"::warning::{p} main() signature not found")
PY

echo "Patch complete."
