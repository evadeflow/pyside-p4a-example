# pyside-p4a-example

Packaging a PySide6 application into a single Android APK with Qt's
`pyside6-android-deploy`, on Ubuntu 24.04 (WSL2), targeting `arm64-v8a`.

It works — but the toolchain is a technical preview riding a fork of
python-for-android that was never merged upstream, and it does not build out
of the box. This repo records exactly what breaks and how to get past it, so
the next build takes minutes instead of an afternoon.

Verified end to end on a Google Pixel Tablet: APK installs, launches, and
renders a PySide6 `QMainWindow` full-screen in landscape.

```
build/democontrolui-0.1-arm64-v8a-debug.apk   ~157 MB
package                                        org.democontrolui.democontrolui
minSdk / targetSdk                             21 / 31
abi                                            arm64-v8a
bundled interpreter                            CPython 3.11.13
```

## Quick start

```bash
sudo apt-get install -y autoconf automake libtool pkg-config openjdk-17-jdk zip unzip ccache
./build.sh
```

First run downloads ~3.5 GB (NDK, SDK, Qt wheels) and cross-compiles CPython;
budget 20-40 minutes. Later runs reuse all of it.

Then:

```bash
adb install -r build/democontrolui-0.1-arm64-v8a-debug.apk
```

## Layout

| Path | Purpose |
|---|---|
| `build.sh` | end-to-end build; idempotent |
| `patches/apply_patches.py` | the four source patches, applied to the build venv only |
| `app/main.py` | the application; entry point **must** be named `main.py` |

Nothing outside `build/`, `~/.buildozer` and `~/.pyside6_android_deploy` is
modified, except `~/.gradle/gradle.properties` when a proxy is detected (the
previous file is backed up).

## Hard constraints

**Python 3.11, not negotiable.** Qt publishes Android wheels for `cp311` only:

```
pyside6-6.11.2-6.11.2-cp311-cp311-android_aarch64.whl
shiboken6-6.11.2-6.11.2-cp311-cp311-android_aarch64.whl
```

Note the tag is `cp311-cp311`, **not** `cp311-abi3`. PyPI's desktop wheels
*are* stable-ABI (`cp310-abi3-manylinux_2_34_x86_64`, usable on 3.10+), so it
is easy to assume the same latitude applies here. It does not — the Android
build links Python differently:

```
# Android wheel                          # desktop manylinux wheel
Tag: cp311-cp311-android_aarch64         Tag: cp310-abi3-manylinux_2_34_x86_64
NEEDED libpython3.11.so                  (no libpython dependency at all)
NEEDED libc++_shared.so                  NEEDED libstdc++.so.6
NEEDED libdl.so                          NEEDED libm.so.6
NEEDED libc.so                           NEEDED libc.so.6
```

On desktop Linux, CPython extension modules do not link against libpython --
their symbols resolve from the interpreter executable, which is what lets one
`abi3` wheel serve many Python versions. python-for-android instead builds
Python as a shared library, so extensions link it explicitly and the soname
`libpython3.11.so` is recorded in the ELF `DT_NEEDED` entries. `.abi3.so` in
the *filename* refers to the limited API symbol set; it says nothing about
which libpython soname the linker wrote down.

Hence the failure below is a `dlopen` failure, not an import error, and no
amount of ABI compatibility gets around it. Verify for yourself with:

```bash
readelf -d shiboken6/libshiboken6.abi3.so | grep NEEDED
```

**The app name must be a valid Java identifier.** python-for-android derives
the package as `org.<name>.<name>`, so a hyphen fails at the very last step,
after the whole cross-compile:

```
Namespace 'org.demo-control-ui.demo-control-ui' is not a valid Java package
name as 'demo-control-ui' is not a valid Java identifier.
```

**The entry point must be `main.py`.** Not configurable.

## What breaks, and why

Each of these stops the build dead. They surface one at a time, several of
them only after a long compile, which is what makes this expensive to
rediscover.

### 1. p4a `develop` builds CPython 3.14; the wheels need 3.11

The most expensive failure, because the APK *builds successfully* and then
dies on launch:

```
dlopen failed: library "libpython3.11.so" not found:
  needed by libshiboken6.abi3.so
E QtLoader: Loading Qt native libraries failed
I python  : Python for android ended.
```

The deploy tool pins `p4a.branch = develop` with this comment in its own
source:

```python
# by default the master branch is used
# ... has not been merged to master yet. So, we use the develop branch for now
```

`develop` has since moved its `python3` recipe to 3.14.2, while the Qt wheels
are still `cp311`. Fix: pin `p4a.commit` to
`3762c88c56e3443efb8eba2a02a2604b680240fd` (2025-10-26) — the newest `develop`
commit whose `python3` recipe is still 3.11.13 *and* which already has the
`qt` bootstrap and the `--qt-libs`, `--load-local-libs` and `--init-classes`
flags the deploy tool passes.

The cutover, for future re-pinning:

| commit | date | python3 recipe |
|---|---|---|
| `2ebea90d` | 2025-07-25 | 3.11.5 |
| `6b66944a` | 2025-10-08 | 3.11.13 |
| **`3762c88c`** | **2025-10-26** | **3.11.13** ← last one |
| `e1bd2497` | 2025-10-28 | 3.14.0 |
| `e772ad93` | 2026-09-10 | 3.14.2 |

### 2. `download_android_ndk()` never returns anything

`PySide6/scripts/deploy_lib/android/android_utilities.py` downloads and
unpacks the NDK, then falls off the end of the function. The caller does
`self.ndk_path = download_android_ndk(...)`, so `ndk_path` is always `None`:

```
TypeError: unsupported operand type(s) for /: 'NoneType' and 'str'
```

Compounded by `android_config.py`, where the whole NDK-resolution block is
guarded by `elif not existing_config_file:` — so once a `pysidedeploy.spec`
has been written, a rerun skips NDK discovery entirely and fails the same way
even with a populated cache.

`build.sh` sidesteps both: it fetches the NDK itself, passes `--ndk-path`
explicitly (CLI takes priority), and deletes any stale `pysidedeploy.spec`.

### 3. buildozer's downloader is broken

Apache Ant and the SDK command-line tools are fetched with
`urllib.request.urlretrieve`, which fails here:

```
File "buildozer/targets/android.py", line 348, in _install_apache_ant
  self.buildozer.download(url, ...)
ValueError: read of closed file
```

`curl` fetches the identical URLs fine, so `download()` is patched to shell
out to it.

**Watch for the poisoned-cache trap:** a failed download leaves a 0-byte zip
inside `~/.buildozer/android/platform/android-sdk/`. buildozer early-returns
when that directory exists, so every later build reports "Android SDK found"
and then fails with `sdkmanager ... does not exist` — because nothing was ever
unpacked. `build.sh` unpacks to a temporary directory and moves it into place
only on success.

### 4. The JVM ignores `http_proxy` / `https_proxy`

On a machine whose only egress is an HTTP proxy, every sdkmanager call fails:

```
Warning: Failed to connect to host: https://dl.google.com/.../addons_list-3.xml
java.net.UnknownHostException: dl.google.com
```

…while `curl` gets HTTP 200 from that exact URL, because curl honours the
environment variables and the JVM does not. Three separate places need
telling:

- **sdkmanager** — its own `--proxy=http --proxy_host=... --proxy_port=...`
  flags (patched into buildozer's `_sdkmanager`)
- **Gradle** — `systemProp.*` keys in `~/.gradle/gradle.properties`
- **anything using `JAVA_OPTS`** — note the sdkmanager start script `eval`s
  it, so an unescaped `|` in `-Dhttp.nonProxyHosts=localhost|127.0.0.1`
  becomes a shell pipe and corrupts the whole option string

### 5. `pip install --user` inside a virtualenv

buildozer bootstraps python-for-android's dependencies with `--user`
regardless of where it is running:

```
ERROR: Can not perform a '--user' install.
User site-packages are not visible in this virtualenv.
```

Setting `include-system-site-packages = true` in `pyvenv.cfg` re-enables
`site.ENABLE_USER_SITE` and lets it through. Harmless here because the venv's
base interpreter is a standalone 3.11 whose site-packages is empty.

Also: the deploy tool shells out to `python -m pip`, so the venv needs `pip`
installed explicitly — a `uv venv` does not ship one.

### 6. The patches must target buildozer 1.5.0 exactly

Subtle and easy to lose an afternoon to. `pysidedeploy.spec` declares:

```
android_packages = buildozer==1.5.0,cython==0.29.33
```

and the deploy tool runs `pip install --force ...` for those at the start of
every build — but only when the exact versions are missing. When they are
present it logs:

```
INFO:root:[DEPLOY] package: buildozer==1.5.0 already installed
```

and skips. So install buildozer **pinned to 1.5.0 before patching**. Install
anything else and one of two things happens: the `--force` reinstall reverts
your patches mid-build, or — since a plain `pip install buildozer` currently
resolves to **1.6.0**, where `download()` has been rewritten — the patch fails
to apply at all because the anchor text no longer exists.

`patches/apply_patches.py` fails loudly rather than silently mis-applying if
any anchor is not found exactly once.

### 7. buildozer needs `cython` and `javac` on `PATH`

Not merely importable. Invoking the tool by absolute path without putting the
venv's `bin/` on `PATH` gives:

```
# Cython (cython) not found, please install it.
```

And `java` must be **17** — the Android Gradle plugin rejects 8, which is
still the default alternative on some Ubuntu installs.

### 8. Portrait letterboxing

buildozer defaults to portrait with the system bars visible, so on a landscape
tablet the app renders as a portrait slab with black bars either side. Set
`orientation` and `fullscreen` in the generated spec.

`orientation` accepts only `landscape`, `portrait`, `landscape-reverse`,
`portrait-reverse` — anything else (`sensorLandscape`, say) is rejected during
spec validation:

```
[app] "sensorLandscape" is not a valid  value for "orientation"
```

The Android status bar and the tablet taskbar still draw over the app; hiding
those needs immersive mode, which is an application-level concern rather than
a packaging flag.

## A trap worth knowing about: uv hardlinks

`uv` installs packages by hardlinking out of its shared cache, so a file in a
virtualenv is often the *same inode* as `~/.cache/uv/archive-v0/...`. Editing
it in place — which is what `open(path, "w")` and `Path.write_text` do —
rewrites the cache too, and every later `uv pip install` of that package on
that machine silently hands out the patched file.

That is how a "patch the venv only" change leaks machine-wide. It also makes
the patches look mysteriously pre-applied in a freshly created venv.

`apply_patches.py` writes a temporary file and renames it over the target, so
a new inode is created and the cache is untouched. If you ever hit this,
`uv cache clean <pkg>` plus deleting the offending `archive-v0/` entry
restores it.

## Notes on the app itself

`app/main.py` tracks `QScreen.geometryChanged` and re-applies the screen
geometry. That is load-bearing when running under Termux:X11 — whose X server
reports a placeholder 1280x1024 until its Android activity attaches — but is
effectively a no-op in the APK, where Qt gets a correctly sized native window
from the start. It is kept so the same file runs unmodified in both.

## Versions this was verified against

| | |
|---|---|
| PySide6 / shiboken6 | 6.11.2 |
| python-for-android | `3762c88c` (develop, 2025-10-26) |
| buildozer | 1.5.0 |
| Android NDK | r27c |
| Android SDK cmdline-tools | 6514223 |
| JDK | OpenJDK 17.0.20 |
| Host | Ubuntu 24.04.4 (WSL2), Python 3.11.14 |
| Device | Google Pixel Tablet, Android 16 |
