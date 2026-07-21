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
CORE_CMAKE="$SDK_DIR/src/core/CMakeLists.txt"
python3 - "$CORE_CMAKE" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
s = p.read_text()
if "list(REMOVE_ITEM rexcore" in s and "fiber_posix.cpp" in s:
    print(f"::notice::{p} already excludes fiber/exception_handler on Android")
else:
    addition = """
# Android: drop sources that depend on ucontext.h or x86_64-only regs.
if(ANDROID)
    list(REMOVE_ITEM rexcore
        fiber_posix.cpp
        exception_handler_posix.cpp
    )
endif()
"""
    # Append near the end of file (after all target_* calls).
    s = s.rstrip() + "\n" + addition
    p.write_text(s)
    print(f"::notice::{p} patched: fiber_posix.cpp + exception_handler_posix.cpp excluded on Android")
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
#    android_* activity symbols used elsewhere in the SDK).  Insert AFTER
#    the existing `if(UNIX) ... elseif(WIN32) ... endif()` block so we
#    don't break its flow control.
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
    new = """if(UNIX)
    target_link_libraries(rexcore PRIVATE pthread dl)
    if(NOT APPLE)
        target_link_libraries(rexcore PRIVATE rt)
    endif()
elseif(WIN32)
    target_link_libraries(rexcore PUBLIC ws2_32)
endif()
if(ANDROID)
    target_link_libraries(rexcore PRIVATE android log)
endif()"""
    if old in s:
        s = s.replace(old, new)
        p.write_text(s)
        print(f"::notice::{p} patched: link libandroid + liblog on Android")
    else:
        print(f"::warning::{p} UNIX/WIN32 link block not found, libandroid not added")
PY

echo "Patch complete."
