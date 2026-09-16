# Android

## Build

```sh
ANDROID_NDK_HOME=$ANDROID_NDK_ROOT sh scripts/build_android.sh
```

| Output | Content |
|---|---|
| `zig-out/android/jniLibs/<abi>/libzeptun.so` | engine, ready for `src/main/jniLibs` |
| `zig-out/android/prebuilt/<abi>/libzeptun.a` | static library the NDK build links |
| `zig-out/android/jniLibs/<abi>/libzeptun-jni.so` | JNI bridge, built by `ndk-build` |

ABIs are `armeabi-v7a`, `arm64-v8a`, `x86` and `x86_64`. Load segments are aligned to 16 KB, which Android 15 and later require. `Application.mk` sets `APP_PLATFORM := android-24`; change it there if you support older devices.

Without the NDK the script still produces the Zig libraries, which is all an application needs if it calls the [C API](C-API) directly.

## Kotlin

`libzeptun-jni.so` registers its methods on the class `dev.zeptun.Zeptun`. Change `ZEPTUN_JNI_CLASS` in `src/jni/zeptun_jni.c` to use another package or class name.

```kotlin
package dev.zeptun

object Zeptun {
    external fun nativeStart(service: Any?, fd: Int, config: String?): Int
    external fun nativeStop()
    external fun nativeVersion(): String
    external fun nativeCounter(index: Int): Long

    init {
        System.loadLibrary("zeptun-jni")
    }
}
```

```kotlin
class ZeptunService : VpnService() {
    private var descriptor: ParcelFileDescriptor? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val builder = Builder()
            .setSession("Zeptun")
            .setMtu(8500)
            .addAddress("172.19.0.1", 30)
            .addRoute("0.0.0.0", 0)
            .addDnsServer("172.19.0.2")
        descriptor = builder.establish() ?: return START_NOT_STICKY

        val config = """
            preset = "mobile"

            [handler]
            kind = "socks5"

            [handler.socks5]
            server = "127.0.0.1:1080"

            [dns]
            hijack = true
        """.trimIndent()

        val rc = Zeptun.nativeStart(this, descriptor!!.fd, config)
        if (rc != 0) stopSelf()
        return START_STICKY
    }

    override fun onRevoke() {
        Zeptun.nativeStop()
        super.onRevoke()
    }

    override fun onDestroy() {
        Zeptun.nativeStop()
        descriptor?.close()
        descriptor = null
        super.onDestroy()
    }
}
```

`nativeStart` takes the descriptor from `VpnService.Builder.establish()` and an optional TOML document; passing `null` starts from the mobile preset. The service object is held as a global reference and its `protect(int)` method is called for every upstream socket, which is what keeps proxy traffic out of the tunnel. `nativeCounter(index)` reads one field of the statistics snapshot, in the order the fields appear in `ZeptunStats` after `version` and `workers`.

The bridge runs the engine on its own thread, so `nativeStart` returns immediately and `nativeStop` joins it.

## Routing without root

The system owns the routes: whatever `VpnService.Builder` is told to include or exclude is what reaches the tunnel. Use `addRoute`, `addDisallowedApplication` and `addAllowedApplication` on the builder, and leave `auto_route` off in the configuration.

## Routing with root

On a rooted device the engine can create `/dev/tun` itself and install policy rules like it does on desktop Linux, including `--include-package` and `--exclude-package`, which resolve app names through `/data/system/packages.list` for every Android user. The mark bit 0x200000 keeps netd's network selection intact.

## Memory

The mobile preset uses a single queue, no offload, the userspace stack, 64 KB windows and a 24 MB memory budget. `[memory] budget_bytes` bounds packet buffers and session tables together, which is the simplest way to keep a VPN service inside the platform's limit.
