# Building

Zig 0.16.0 is the only requirement. There are no submodules and no vendored C libraries.

## Unix

```sh
git clone https://github.com/Noisemux/zeptun
cd zeptun
make
sudo make install
```

| Path | Content |
|---|---|
| `$(PREFIX)/bin/zeptun` | command line tool |
| `$(PREFIX)/lib/libzeptun.a` | static library |
| `$(PREFIX)/include/zeptun.h` | public header |
| `/etc/zeptun/zeptun.toml` | sample configuration, never overwritten |
| `$(PREFIX)/lib/systemd/system/zeptun.service` | hardened unit |

`PREFIX`, `DESTDIR`, `OPTIMIZE`, `TARGET` and `CPU` are honoured: `make TARGET=aarch64-linux-musl OPTIMIZE=ReleaseSmall`.

## Zig directly

```sh
zig build -Doptimize=ReleaseFast
zig build cross
```

| Step | Result |
|---|---|
| `zig build` | CLI, bench tool, static and shared library, header |
| `zig build cross` | libraries for the whole target matrix in `zig-out/cross/<triple>` |
| `zig build android` | `zig-out/android/jniLibs/<abi>/libzeptun.so` and static libraries for the NDK |
| `zig build ios` | ReleaseSmall slices for the XCFramework |

Feature flags trim the binary: `-Dipv6=false`, `-Dsocks5=false`, `-Droute=false`, `-Dicmp=false`, `-Dfragments=false`, `-Dsystem-stack=false`, `-Duserspace-tcp=false`, `-Dmobile=true`, `-Dstrip=true`.

## Android

```sh
ANDROID_NDK_HOME=/path/to/ndk sh scripts/build_android.sh
```

Builds `libzeptun.so` and `libzeptun.a` for `armeabi-v7a`, `arm64-v8a`, `x86` and `x86_64`, then `libzeptun-jni.so` from `src/jni/zeptun_jni.c`. Load segments are aligned to 16 KB for Android 15 and later. Without the NDK the script stops after the Zig libraries. See [Android](Android).

## iOS and macOS

```sh
sh scripts/make_xcframework.sh
```

Produces `zig-out/Zeptun.xcframework` with iOS device, iOS simulator and macOS slices. `Package.swift` exposes it to SwiftPM. See [Apple](Apple).

## Windows

```sh
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast
make wintun
```

The tunnel uses Wintun. The released Windows archives ship `wintun.dll` beside `zeptun.exe`, which is where the loader looks first, so a downloaded release needs no extra step. For a local build, `make wintun` downloads the official distribution, checks its SHA-256 and places the right library in `zig-out/bin`; pass `WINTUN_ARCH=arm64` for arm64 hosts. `scripts/fetch_wintun.sh ARCH DIR` does the same for any directory.

MSVC targets build as well: `-Dtarget=x86_64-windows-msvc`.

## Container

```sh
docker build -t zeptun .
```

The image builds from source with Zig on Alpine and ships a single static binary. See [Container](Container).

## Released binaries

The `release` workflow publishes, for every tagged release: thirteen Linux architectures as static musl binaries, a macOS universal binary, Windows x86_64 and arm64 archives, FreeBSD x86_64, the Android `jniLibs` archive, the XCFramework, a source tarball and `SHA256SUMS`, plus a multi-architecture image on `ghcr.io/noisemux/zeptun`.
