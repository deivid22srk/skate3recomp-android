# skate3recomp - Android Port

This is an **experimental Android port** of [skate3recomp](https://github.com/mchughalex/skate3recomp),
the static recompilation of Skate 3 (Xbox 360) to modern platforms.  It cross-compiles
the native `libskate3.so` runtime for `arm64-v8a` using the Android NDK and packages
it with a SDL2-based bootstrap APK, mirroring the approach used by
[UnleashedRecomp-Android](https://github.com/SansNope/UnleashedRecomp-Android).

## Repository layout

```
.
├── CMakeLists.txt            # main skate3 build (patches for Android)
├── CMakePresets.json         # adds android-arm64 preset
├── src/                      # skate3 C++ sources
├── third_party/rexglue-sdk/  # ReXGlue SDK (submodule)
├── android-apk/              # Gradle Android project that wraps libskate3.so
│   ├── app/
│   │   ├── build.gradle
│   │   ├── src/main/AndroidManifest.xml
│   │   ├── src/main/java/org/libsdl/app/   # SDL2 Java entry points
│   │   ├── src/main/res/                    # strings, icons, themes
│   │   └── jni/                             # ndk-build: libmain.so (SDL2 bootstrap)
│   ├── gradle/
│   ├── gradlew
│   └── build.gradle
└── .github/workflows/build.yml   # CI: builds libskate3.so + APK
```

## Status

**Experimental / WIP.**  The full native port requires:

1. The `rexglue-sdk` Vulkan backend compiling cleanly for Android arm64.
2. Generated recompilation sources (produced by the codegen tools from a
   Skate 3 retail game dump).  These are **not** redistributable and must
   be supplied by each builder.
3. Touch / gamepad input mapping (SDL2 handles most of this; the rest is
   handled by the rexglue UI layer).

The CI workflow therefore attempts the full native build, and on failure
falls back to a stub `libskate3.so` that surfaces a friendly message box
so the pipeline still produces an installable debug APK.  This lets you
iterate on the port without a working game-data pipeline.

## Local build (skip CI)

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

cd android-apk/app/jni && curl -sSL https://github.com/libsdl-org/SDL/archive/refs/tags/release-2.30.6.tar.gz | tar xz && mv SDL-2.30.6 SDL && cd -
cd android-apk && ./gradlew assembleDebug
```

## Providing game files

The workflow reads optional Skate 3 game data from a private repository
configured via repository **variable** `GAME_FILES_REPO` and **secret**
`GAME_FILES_TOKEN`.  The private repo should contain:

```
default.xex
default.xexp
generated/                 # output of the rexglue codegen tools
generated/sources.cmake
generated/eawebkit/sources.cmake
```

## License

Same as upstream skate3recomp.  See the original project for details.
