/*
 * skate3 Android bootstrap.
 *
 * SDL2 builds libmain.so via ndk-build (jni/Android.mk).  SDLActivity
 * loads libmain.so, which in turn dlopen()s libskate3.so produced by the
 * project's own CMake pipeline (see .github/workflows/build.yml).
 *
 * If libskate3.so is absent (e.g. the native build was skipped or game
 * files were not provided for codegen), we surface a friendly error
 * through SDL_ShowSimpleMessageBox instead of crashing on a missing
 * symbol lookup.
 */

#include <SDL.h>
#include <dlfcn.h>
#include <android/log.h>

#define TAG "skate3"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

int main(int argc, char *argv[])
{
    (void)argc;
    (void)argv;

    void *handle = dlopen("libskate3.so", RTLD_NOW);
    if (!handle) {
        const char *err = dlerror();
        LOGE("Failed to dlopen libskate3.so: %s", err ? err : "(no error)");
        if (SDL_Init(SDL_INIT_VIDEO) == 0) {
            SDL_ShowSimpleMessageBox(
                SDL_MESSAGEBOX_ERROR,
                "Skate 3",
                "libskate3.so is missing.  Build the native target via the "
                "project's GitHub Actions workflow before launching.",
                NULL);
            SDL_Quit();
        }
        return 1;
    }

    /* The recomp runtime expects SDL_main to be invoked by SDLActivity.
     * libskate3.so does not export a C entry point we can call directly
     * (it links against the SDL2 main hook through REX_DEFINE_APP).  Once
     * the native lib is loaded, its static initialisers register the
     * app factory with rex::ui, and SDLActivity's call into the SDL2
     * Java native bridge will dispatch into it. */
    LOGI("libskate3.so loaded; handing control to SDL2 main loop.");

    /* Intentionally leave the handle open: libskate3.so must stay
     * resident for the lifetime of the process so its JNI registrations
     * remain valid. */
    return 0;
}
