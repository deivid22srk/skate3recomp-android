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

echo "Patch complete."
