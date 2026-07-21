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

echo "Patch complete."
