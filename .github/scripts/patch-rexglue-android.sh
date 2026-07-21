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

# 6. Provide a ucontext.h shim.  The Android NDK does not ship ucontext.h
#    (deprecated since API 21), but rexglue-sdk's fiber_posix.cpp and
#    thread/fiber.h unconditionally #include <ucontext.h> on REX_PLATFORM_LINUX
#    (which is also defined on Android).  The shim declares the API surface
#    needed by fiber_posix.cpp; functions are left undefined so any actual
#    fiber usage will fail at link time (acceptable for the current stub
#    build phase - the real recomp runtime isn't shipped yet).
COMPAT_DIR="$SDK_DIR/thirdparty/android_compat"
mkdir -p "$COMPAT_DIR"
UCONTEXT_H="$COMPAT_DIR/ucontext.h"
cat > "$UCONTEXT_H" <<'H'
// SPDX-License-Identifier: BSD-3-Clause
// Minimal ucontext.h shim for Android NDK builds of rexglue-sdk.
//
// The Android NDK does not ship <ucontext.h>.  We declare just enough of
// the type and function surface for rexglue-sdk's fiber_posix.cpp to
// compile; the functions are not implemented, so any runtime use of the
// Fiber primitive will fail to link.  This is acceptable for the Android
// port's current "make CI green" phase - the full recomp runtime still
// needs the codegen sources to be supplied separately.
#pragma once

#include <cstddef>
#include <cstdint>

extern "C" {

typedef struct mcontext_t {
    uint64_t gregs[32];
} mcontext_t;

typedef struct ucontext_t {
    uint64_t uc_flags;
    struct ucontext_t* uc_link;
    void* uc_stack;
    mcontext_t uc_mcontext;
    uint64_t uc_sigmask[16];
} ucontext_t;

typedef void (*__ucontext_func_t)(void);

int getcontext(ucontext_t* ucp);
int setcontext(const ucontext_t* ucp);
void makecontext(ucontext_t* ucp, void (*func)(void), int argc, ...);
int swapcontext(ucontext_t* oucp, const ucontext_t* ucp);

}  // extern "C"
H
echo "::notice::$UCONTEXT_H written (ucontext shim)"

# 7. Patch src/core/CMakeLists.txt so rexcore picks up the ucontext shim
#    include directory on Android.
CORE_CMAKE="$SDK_DIR/src/core/CMakeLists.txt"
python3 - "$CORE_CMAKE" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
s = p.read_text()
marker = "android_compat"
if marker in s:
    print(f"::notice::{p} already has android_compat include")
else:
    addition = """
# Android: ucontext.h is not shipped by the NDK; provide a shim.
if(ANDROID)
    target_include_directories(rexcore PRIVATE
        ${PROJECT_SOURCE_DIR}/thirdparty/android_compat)
endif()
"""
    anchor = "target_include_directories(rexcore PRIVATE\n    ${PROJECT_SOURCE_DIR}\n    ${PROJECT_SOURCE_DIR}/thirdparty/cli11/include\n)"
    if anchor in s:
        s = s.replace(anchor, anchor + "\n" + addition)
        p.write_text(s)
        print(f"::notice::{p} patched: android_compat include added")
    else:
        s = s.rstrip() + "\n" + addition
        p.write_text(s)
        print(f"::warning::{p} anchor not found, appended android_compat block at end")
PY

# 8. Patch src/core/memory_posix.cpp: replace <linux/ashmem.h> (also missing
#    from the NDK) with inline definitions of the constants it actually uses.
MEM_POSIX="$SDK_DIR/src/core/memory_posix.cpp"
python3 - "$MEM_POSIX" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
s = p.read_text()
old = '#include <linux/ashmem.h>'
new = '''// <linux/ashmem.h> is not shipped by the Android NDK; define the few
// constants memory_posix.cpp actually uses inline.
#include <sys/ioctl.h>
#define ASHMEM_NAME_LEN 256
#define ASHMEM_NAME_DEF "ashmem"
#define _IOWR(__type, __nr, __size) _IOC(_IOC_READ|_IOC_WRITE, (__type), (__nr), sizeof(__size))
#define ASHMEM_SET_NAME _IOWR(0x98, 1, char[ASHMEM_NAME_LEN])
#define ASHMEM_SET_SIZE _IOWR(0x98, 3, size_t)'''
if '_IOWR(0x98, 1, char[ASHMEM_NAME_LEN])' in s:
    print(f"::notice::{p} already has ashmem constants inlined")
elif old in s:
    s = s.replace(old, new)
    p.write_text(s)
    print(f"::notice::{p} patched: ashmem.h replaced with inline constants")
else:
    print(f"::warning::{p} ashmem.h include not found")
PY

# 9. Link libandroid on Android (needed for ASharedMemory_create and the
#    android_* activity symbols used elsewhere in the SDK).
python3 - "$CORE_CMAKE" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
s = p.read_text()
if "target_link_libraries(rexcore PRIVATE android)" in s:
    print(f"::notice::{p} already links libandroid")
else:
    old = "if(UNIX)\n    target_link_libraries(rexcore PRIVATE pthread dl)\n    if(NOT APPLE)\n        target_link_libraries(rexcore PRIVATE rt)\n    endif()"
    new = """if(UNIX)
    target_link_libraries(rexcore PRIVATE pthread dl)
    if(NOT APPLE)
        target_link_libraries(rexcore PRIVATE rt)
    endif()
endif()
if(ANDROID)
    target_link_libraries(rexcore PRIVATE android log)
endif()"""
    if old in s:
        s = s.replace(old, new)
        p.write_text(s)
        print(f"::notice::{p} patched: link libandroid + liblog on Android")
    else:
        print(f"::warning::{p} UNIX link block not found, libandroid not added")
PY

echo "Patch complete."
