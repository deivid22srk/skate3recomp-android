# skate3recomp — Android Port Status

**Last updated:** 2026-07-21 (commit `7a53ae25`, run #27)

This document tracks the current state of the Android port of
[skate3recomp](https://github.com/mchughalex/skate3recomp).  It is
updated every time the build status materially changes.

---

## TL;DR

The build pipeline is **green end-to-end**.  The APK installs, SDL
initialises, and the app opens without native crashes.  However, the
runtime cannot run any Skate 3 game code yet because the
`generated/` codegen sources (produced from a legally-owned Skate 3
retail dump) are not present in CI.  Without those sources, the build
falls back to a stub `libskate3.so` that shows an informational
message box at startup.

---

## What works

- **CI workflow** (`.github/workflows/build.yml`) runs end-to-end on
  `ubuntu-24.04`, all 21 steps green:
  - NDK 29.0.14206865 + vcpkg + ccache
  - CMake configure with `SKATE3_ANDROID=ON`
  - Native build of `librexruntime.so` (the rexglue-sdk runtime) —
    **links cleanly with zero undefined symbols**
  - ndk-build of `libmain.so` + `libSDL2.so` via SDL 2.32.4
  - Gradle `assembleDebug` produces a signed-debug APK
  - APK published as a GitHub Actions artifact

- **APK contents** (verified from run #27 artifact):
  ```
  lib/arm64-v8a/libSDL2.so       2,113,432 bytes  (real, SDL 2.32.4)
  lib/arm64-v8a/libc++_shared.so 1,374,336 bytes  (C++ runtime)
  lib/arm64-v8a/libmain.so           5,208 bytes  (real, ndk-build)
  lib/arm64-v8a/libskate3.so         4,464 bytes  (STUB — see below)
  AndroidManifest.xml                4,612 bytes
  ```

- **Native libraries that link cleanly:**
  - `librexruntime.so` — the rexglue-sdk runtime, ~795 of 807 compile
    units, including:
    - `rexcore` (with `fiber_android.cpp`, `exception_handler_android.cpp`,
      `filesystem_android.cpp` stubs — see "Stubbed functionality" below)
    - `rexfilesystem`, `rexgraphics` (Vulkan backend), `rexui` (ImGui +
      Vulkan presenter), `rexaudio` (with FFmpeg XMA/WMA Pro decoder),
    `rexinput` (SDL), `rexruntime` (Xbox 360 kernel + XAM + XDBM +
    Xboxkrnl recomp runtime)
  - `libmain.so` — SDL2 bootstrap that `SDLActivity` dlopen()s at startup
  - `libSDL2.so` — SDL 2.32.4, built from source via ndk-build

- **Java side:**
  - `SDLActivity.java` version constants correctly set to `2.32.4`
    (matches the native `libSDL2.so`)
  - All SDL2 Java entry points (`SDLActivity`, `SDLSurface`,
    `SDLControllerManager`, etc.) inherited from the
    UnleashedRecomp-Android reference port

- **Android-specific patches applied to rexglue-sdk**
  (via `.github/scripts/patch-rexglue-android.sh`, idempotent):
  1. SDL3 backend enabled on Android (instead of GTK3/X11-XCB)
  2. SDL_VIDEO / SDL_VULKAN enabled in vendored SDL3 build
  3. `rexglue_helpers.cmake` skips GTK3 lookup on Android, uses
     `windowed_app_main_sdl.cpp` instead of `windowed_app_main_posix.cpp`
  4. `rexcore` source set split: Android branch excludes
     `fiber_posix.cpp` and `exception_handler_posix.cpp` (ucontext /
     x86_64-only regs)
  5. `memory_posix.cpp`: `<linux/ashmem.h>` replaced with inline
     `#define`s; `#include <rex/main_android.h>` added
  6. `threading_posix.cpp`: robust-mutex calls (`pthread_mutexattr_setrobust`,
     `PTHREAD_MUTEX_ROBUST`, `pthread_mutex_consistent`) guarded with
     `#if !defined(__ANDROID__)` (Bionic doesn't have them)
  7. `rexcore` link block split: Android skips `-lpthread` / `-lrt`
     (Bionic has pthread in libc, no librt), adds `-landroid -llog`
  8. `include/rex/ui/surface_android.h` stub: declares
     `AndroidNativeWindowSurface` wrapping `ANativeWindow*` (the SDK
     references this class but never shipped the header)
  9. FFmpeg AArch64 NEON `.S` assembly excluded on Android
     (hand-written `adrp`/`add` relocations are non-PIC, lld rejects
     them in shared links)
  10. FFmpeg `*_init_aarch64.c` dispatcher shims also excluded on
      Android (they reference NEON externs that are no longer compiled)
  11. `thirdparty/FFmpeg/android_stubs.c` provides no-op implementations
      of `ff_float_dsp_init_aarch64`, `ff_fft_init_aarch64`,
      `ff_mpadsp_init_aarch64` so the generic FFmpeg sources
      (`fft_template.c`, `mpegaudiodsp.c`, `float_dsp.c`) link cleanly
      (they call these under `if (ARCH_AARCH64)` which is hard-defined
      to 1 in `config_android_aarch64.h`)
  12. `include/rex/thread/fiber.h` patched: Android branch declares
      empty `Fiber` struct (no `ucontext_t` dependency)
  13. `src/core/fiber_android.cpp` STUB: `Fiber::ConvertCurrentThread`,
      `Create`, `SwitchTo`, `Destroy` (all return nullptr / no-op)
  14. `src/core/exception_handler_android.cpp` STUB: `Install`,
      `Uninstall` (no-op — crash recovery disabled)
  15. `src/core/filesystem_android.cpp` STUB: `IsAndroidContentUri`
      (returns false), `OpenAndroidContentFileDescriptor` (returns -1,
      errno=ENOSYS)
  16. `include/rex/main_android.h` STUB: `rex::GetAndroidApiLevel()`
      returns 29

- **skate3-specific patches:**
  - `CMakeLists.txt` patched with `SKATE3_ANDROID` option that builds
    `libskate3.so` as a shared library (instead of an executable)
  - `CMakePresets.json` adds `android-arm64` preset
  - `src/skate3_iso_installer.cpp` and `src/skate3_title_update_installer.cpp`:
    GTK dependency removed on Android — `#elif defined(__ANDROID__)`
    branches return empty path so callers fall through to the
    rexglue-sdk ImGui-based install wizard overlay; GTK events-pump
    blocks guarded with `#if !defined(__APPLE__) && !defined(__ANDROID__)`

- **Workflow robustness:**
  - If `libskate3.so` real build fails (e.g. because `generated/` is
    missing), CI falls back to a stub `libskate3.so` that shows an
    informational message box at startup — the APK still installs and
    opens, just doesn't run any game code.

---

## What doesn't work (the real blocker)

### Primary blocker: missing `generated/` codegen sources

The skate3 recomp runtime requires a `generated/` directory produced
by the rexglue-sdk codegen tools from a legally-owned Skate 3 retail
dump:

```
generated/
├── skate3_init.h              # PPC image config + entry points
├── sources.cmake              # list of generated .cpp files
├── skate3_*.cpp               # recompiled PPC guest functions
└── eawebkit/
    ├── sources.cmake
    └── *.cpp                  # recompiled EAWebkit module
```

Without these, 5 of the 7 skate3 C++ sources fail to compile with:

```
fatal error: 'generated/skate3_init.h' file not found
```

The 5 affected sources are:
- `src/exception_compat.cpp`
- `src/main.cpp` (via `src/skate3_app_common.h`)
- `src/skate3_app_common.cpp` (via `src/skate3_app_common.h`)
- `src/skate3_demo_path.cpp`
- `src/skate3_title_update_installer.cpp`

(The other 2 skate3 sources — `src/skate3_iso_installer.cpp` and
`src/skate3_fov.cpp` — compile cleanly, but `libskate3.so` cannot be
linked without all 7.)

### How to provide `generated/`

The workflow reads game files from a private repository configured via
the **repository variable** `GAME_FILES_REPO` and **repository secret**
`GAME_FILES_TOKEN` (fine-grained PAT with `Contents: read` on that
single repository).  The private repo must contain at minimum:

```
default.xex                      # Skate 3 retail default.xex
default.xexp                     # Title update patch (optional)
generated/                       # Pre-built codegen output
generated/sources.cmake
generated/eawebkit/sources.cmake
generated/skate3_init.h
generated/*.cpp
```

Or, alternatively, the raw game files (`default.xex`, `default.xexp`)
so the rexglue-sdk codegen tools can run in CI to produce `generated/`.
(The current workflow expects pre-built `generated/`; running codegen
in CI is a future enhancement.)

**This is a legal/licensing blocker, not a technical one.**  The
skate3recomp project requires each builder to supply their own
legally-obtained copy of Skate 3 — the project cannot distribute
the game's copyrighted binary code.

---

## Stubbed functionality (works for build, not for gameplay)

These are areas where the Android port has no-op / stub
implementations so the link succeeds, but the corresponding runtime
functionality is **not implemented**.  Each stub is clearly marked
with a `// STUB Android:` header comment in its source file explaining
the limitation and what a real implementation would require.

| Stub file | What's stubbed | Real impl would need |
|---|---|---|
| `src/core/fiber_android.cpp` | `rex::thread::Fiber::*` (4 methods) | Vendor `libucontext`, or rewrite on `pthread` + `sigaltstack` + custom trampolines |
| `src/core/exception_handler_android.cpp` | `ExceptionHandler::Install` / `Uninstall` | `sigaction` with arm64 `sigcontext` walker (PC, SP, X0..X30) |
| `src/core/filesystem_android.cpp` | `IsAndroidContentUri` / `OpenAndroidContentFileDescriptor` | JNI into `ContentResolver.openFileDescriptor()` + `ParcelFileDescriptor.detachFd()` |
| `thirdparty/FFmpeg/android_stubs.c` | `ff_float_dsp_init_aarch64` / `ff_fft_init_aarch64` / `ff_mpadsp_init_aarch64` | PIC NEON asm (vendored libucontext-style), or accept permanent no-NEON FFmpeg |
| `include/rex/main_android.h` | `rex::GetAndroidApiLevel()` | JNI into `android.os.Build.VERSION.SDK_INT` |
| `include/rex/ui/surface_android.h` | `AndroidNativeWindowSurface` class | Already functional (wraps `ANativeWindow*`); real integration would route through `SDL_Vulkan_CreateSurface` instead |
| `skate3_iso_installer.cpp` (Android branch) | `PickIsoFile()` returns `{}` | Real SAF-based file picker (see "Next steps" below) |
| `skate3_title_update_installer.cpp` (Android branch) | `PickTitleUpdateFile()` returns `{}` | Real SAF-based file picker (see "Next steps" below) |

**Runtime impact:**
- Without real `Fiber`, the recomp runtime cannot run PPC guest code
  (fibers are the cooperative scheduling primitive for guest threads).
  This is the most critical stub — every other stub is moot until
  fibers work.
- Without real `ExceptionHandler`, MMIO write callbacks cannot recover
  from `SIGSEGV` (the runtime would crash instead of dispatching to
  the guest's page-fault handler).
- Without real `OpenAndroidContentFileDescriptor`, content URIs
  (`content://...`) from SAF cannot be opened as file descriptors —
  only regular file paths work.

---

## Next steps (not yet implemented)

These are the technical obstacles that need to be resolved **after**
`generated/` is supplied, in roughly the order they'll be encountered:

1. **Storage Access Framework file picker** (replaces the
   `PickIsoFile` / `PickTitleUpdateFile` stubs)
   - Add `pickFileWithSAF(...)` method to `SDLActivity.java` using
     `ACTION_OPEN_DOCUMENT` + `CATEGORY_OPENABLE` (API 19+)
   - Implement real `rex::filesystem::OpenAndroidContentFileDescriptor`
     via JNI + `ContentResolver.openFileDescriptor()` +
     `ParcelFileDescriptor.detachFd()`
   - Synchronous block on C++ side via `std::promise`/`std::future`
     with 5-minute timeout safety
   - Keep the ImGui wizard as fallback if user cancels the SAF picker

2. **Vulkan runtime initialization**
   - `librexruntime.so` links, but the runtime initialization path
     (`VkInstance` creation, `SDL_Vulkan_CreateSurface`, device
     selection, swapchain) has not been tested on Android
   - Likely issues: Android-specific device extensions
     (`VK_ANDROID_external_memory_android_hardware_buffer` etc.),
     validation layer discovery, Adreno/Mali driver quirks
   - May need to vendor a recent Mesa Turnip driver (as
     UnleashedRecomp-Android does) for older devices

3. **Touch / gamepad input mapping**
   - SDL2 maps touch to mouse by default — fine for UI clicks but
     not for skate gameplay (multiple buttons + analog sticks)
   - Will need either:
     - On-screen touch overlay with configurable button layout
       (like UnleashedRecomp-Android's `LauncherActivity`), or
     - Bluetooth gamepad support (already handled by SDL2's
       `SDLControllerManager`, just needs UI to map buttons to
       Skate 3's XINPUT controller layout)

4. **PPC→ARM recompilation performance**
   - Even with `generated/` provided, the PPC guest code is
     recompiled at runtime by `rexruntime`.  Performance on Android
     arm64 phones (especially non-flagship) may be insufficient
     without additional JIT optimizations
   - The rexglue-sdk already has a SPIR-V shader translator for the
     Xenos GPU; the bottleneck is more likely CPU-side (PPC guest
     instruction dispatch)

5. **Game data installation**
   - Even with `generated/` for codegen, the runtime needs the
     actual game files (`default.xex`, `default.xexp`, asset
     packages) at runtime
   - The `skate3_iso_installer.cpp` code path extracts these from an
     ISO into the app's private data directory — the install wizard
     overlay handles this UI, but it needs the SAF picker (#1) to
     let the user select the ISO file

---

## Build & test

### Building locally

```bash
# 1. Configure with the Android NDK toolchain
cmake --preset android-arm64 \
  -DCMAKE_TOOLCHAIN_FILE=$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-29

# 2. Build the native lib
cmake --build out/build/android-arm64 --target skate3

# 3. Stage into jniLibs and build APK
mkdir -p android-apk/app/src/main/jniLibs/arm64-v8a
cp out/build/android-arm64/libskate3.so android-apk/app/src/main/jniLibs/arm64-v8a/

cd android-apk/app/jni && \
  curl -sSL https://github.com/libsdl-org/SDL/archive/refs/tags/release-2.32.4.tar.gz | tar xz && \
  mv SDL-release-2.32.4 SDL && \
  cd -

cd android-apk && ./gradlew assembleDebug
```

### Testing on a device

```bash
# 1. Download the APK from the latest successful run's artifact:
#    https://github.com/deivid22srk/skate3recomp-android/actions
#    (artifact name: skate3recomp-android-main)

# 2. Install on the device (USB debugging enabled):
adb install -r app-debug.apk

# 3. Launch the app:
adb shell am start -n com.ea.skate3/.SDLActivity

# 4. Capture logcat with relevant tags:
adb logcat -c  # clear buffer first
adb logcat -s SDLActivity:V SDL:V skate3:V libc:V DEBUG:V AndroidRuntime:V

# 5. Uninstall when done:
adb uninstall com.ea.skate3
```

**Expected behaviour** (current build with stub `libskate3.so`):
- App opens, SDL window initializes
- A message box appears: "Skate 3 Recomp (Android port) — Native
  libskate3.so could not be built in CI yet. Provide Skate 3 retail
  game files via the GAME_FILES_REPO secret, and ensure the
  rexglue-sdk Vulkan backend compiles for Android arm64-v8a."
- App exits cleanly when the user dismisses the message box
- No native crash, no `dlopen` errors, no SDL version mismatch

---

## Run history

| Run # | Commit | Status | Notes |
|---|---|---|---|
| 1-7 | (various) | failure | Initial port: CMake / NDK / SDL2 version issues |
| 8 | `5dc8fb1` | success (stub) | First green CI — stub `libskate3.so`, APK produced |
| 11-13 | `7cebca5`, `162fcd8`, `0749654` | failure | rexglue-sdk core patches (CMake flow control, surface_android.h, ndk-build module order) |
| 15 | `dc3f3a0` | failure | SDL2 bump to 2.32.4 + FFmpeg `-fPIC` attempt |
| 17 | `dc3f3a0` | success (stub) | Same commit, FFmpeg NEON `.S` excluded on Android |
| 19 | `7eb57fd` | success (stub) | FFmpeg `*_init_aarch64.c` also excluded (Option A) |
| 21 | `c512c5e` | success (stub) | librexruntime.so still failed with 10 undefined symbols (Fiber, ExceptionHandler, filesystem, FFmpeg) |
| 23 | `78994a4` | success (stub) | **librexruntime.so links cleanly!** All 10 undefined symbols resolved by stubs. New blocker: 5 skate3 sources fail on missing `generated/skate3_init.h` |
| 25 | `7179054` | success (stub) | `skate3_iso_installer.cpp` GTK removed; new blocker: `skate3_title_update_installer.cpp` also has GTK + second `gtk_events_pending` usage missed |
| 27 | `7a53ae2` | success (stub) | All GTK deps removed from both installers. Only remaining blocker is `generated/skate3_init.h` (documented, requires `GAME_FILES_REPO`). |

---

## License

Same as upstream [skate3recomp](https://github.com/mchughalex/skate3recomp).
The Android port does not introduce any new licensing constraints.
