#!/usr/bin/env bash
#
# Build a PySide6 application into an Android APK with pyside6-android-deploy.
#
# See README.md for why each of the workarounds below is necessary. Running
# this twice is safe: everything is cached or skipped if already done.
#
set -euo pipefail

PYSIDE_VERSION=${PYSIDE_VERSION:-6.11.2}
APP_NAME=${APP_NAME:-democontrolui}      # must be a valid Java identifier
ANDROID_ARCH=${ANDROID_ARCH:-aarch64}
NDK_VERSION=${NDK_VERSION:-r27c}
ANT_VERSION=${ANT_VERSION:-1.9.4}
CMDLINE_TOOLS=${CMDLINE_TOOLS:-commandlinetools-linux-6514223_latest.zip}

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BUILD_DIR=${BUILD_DIR:-$HERE/build}
VENV=$BUILD_DIR/.venv
PY=$VENV/bin/python

DEPLOY_CACHE=$HOME/.pyside6_android_deploy
NDK_DIR=$DEPLOY_CACHE/android-ndk/android-ndk-$NDK_VERSION
BUILDOZER_PLATFORM=$HOME/.buildozer/android/platform
SDK_DIR=$BUILDOZER_PLATFORM/android-sdk
ANT_DIR=$BUILDOZER_PLATFORM/apache-ant-$ANT_VERSION

QT_DOWNLOADS=https://download.qt.io/official_releases/QtForPython

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }


# ---------------------------------------------------------------------------
# 0. Prerequisites
# ---------------------------------------------------------------------------
say "Checking system prerequisites"

MISSING=()
for pkg in autoconf automake libtool pkg-config openjdk-17-jdk zip unzip ccache; do
    dpkg -s "$pkg" >/dev/null 2>&1 || MISSING+=("$pkg")
done
if [ ${#MISSING[@]} -gt 0 ]; then
    die "Missing system packages. Install them with:

    sudo apt-get install -y ${MISSING[*]}

python-for-android cross-compiles CPython and libffi from source, which needs
the autotools; the Android Gradle plugin needs JDK 17 specifically."
fi

# p4a needs JDK 17. Do not rely on the default alternative.
JAVA_HOME=${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-amd64}
[ -x "$JAVA_HOME/bin/javac" ] || die "JDK 17 not found at JAVA_HOME=$JAVA_HOME"
export JAVA_HOME
export PATH="$JAVA_HOME/bin:$PATH"

command -v curl >/dev/null || die "curl is required"

# If this machine reaches the internet through a proxy, the JVM needs telling
# separately -- it ignores http_proxy/https_proxy entirely.
PROXY=${https_proxy:-${http_proxy:-}}
if [ -n "$PROXY" ]; then
    PROXY_HOST=$(printf '%s' "$PROXY" | sed -E 's#^[a-z]+://##; s#/.*$##; s#:.*$##')
    PROXY_PORT=$(printf '%s' "$PROXY" | sed -E 's#^[a-z]+://##; s#/.*$##; s#^[^:]*:##')
    [ "$PROXY_PORT" = "$PROXY_HOST" ] && PROXY_PORT=80
    say "Proxy detected: $PROXY_HOST:$PROXY_PORT (configuring JVM and Gradle)"

    mkdir -p "$HOME/.gradle"
    if ! grep -q "systemProp.https.proxyHost" "$HOME/.gradle/gradle.properties" 2>/dev/null; then
        [ -f "$HOME/.gradle/gradle.properties" ] && \
            cp "$HOME/.gradle/gradle.properties" "$HOME/.gradle/gradle.properties.bak"
        cat >> "$HOME/.gradle/gradle.properties" <<EOF
# Added by pyside-p4a-example/build.sh: the JVM ignores http_proxy/https_proxy.
systemProp.http.proxyHost=$PROXY_HOST
systemProp.http.proxyPort=$PROXY_PORT
systemProp.https.proxyHost=$PROXY_HOST
systemProp.https.proxyPort=$PROXY_PORT
EOF
    fi
    SDKMANAGER_PROXY=(--proxy=http "--proxy_host=$PROXY_HOST" "--proxy_port=$PROXY_PORT")
else
    SDKMANAGER_PROXY=()
fi


# ---------------------------------------------------------------------------
# 1. Build virtualenv on Python 3.11
# ---------------------------------------------------------------------------
# The Android wheels Qt publishes are cp311 ONLY. Any other Python version
# produces an APK that cannot load shiboken6 at runtime.
say "Creating Python 3.11 build virtualenv"

mkdir -p "$BUILD_DIR"
if [ ! -x "$PY" ]; then
    if command -v uv >/dev/null; then
        uv venv --python 3.11 "$VENV"
    elif command -v python3.11 >/dev/null; then
        python3.11 -m venv "$VENV"
    else
        die "Need Python 3.11 (install uv, or python3.11)"
    fi
fi

"$PY" -c 'import sys; assert sys.version_info[:2] == (3, 11), sys.version' \
    || die "build venv is not Python 3.11"

# buildozer runs `pip install --user` even inside a virtualenv, which pip
# refuses unless user site-packages are visible.
if grep -q '^include-system-site-packages *= *false' "$VENV/pyvenv.cfg"; then
    sed -i 's/^include-system-site-packages *=.*/include-system-site-packages = true/' \
        "$VENV/pyvenv.cfg"
fi

say "Installing build dependencies"
# pyside6-android-deploy shells out to `python -m pip`, so pip must be present
# in the venv even when it was created by uv.
# buildozer and cython MUST be pinned to exactly what pysidedeploy.spec's
# android_packages asks for. The deploy tool runs
#   pip install --force buildozer==1.5.0,cython==0.29.33
# at the start of every build UNLESS those exact versions are already present
# ("package: buildozer==1.5.0 already installed"). Install anything else and
# that --force reinstall silently reverts the patches applied below. A plain
# `pip install buildozer` currently resolves to 1.6.0, whose download() has
# been rewritten and no longer matches the patch anchor at all.
BUILDOZER_VERSION=1.5.0
CYTHON_VERSION=0.29.33

if command -v uv >/dev/null; then
    uv pip install --python "$PY" -q \
        pip "pyside6==$PYSIDE_VERSION" \
        "buildozer==$BUILDOZER_VERSION" "cython==$CYTHON_VERSION"
else
    "$PY" -m pip install -q --upgrade pip
    "$PY" -m pip install -q "pyside6==$PYSIDE_VERSION" \
        "buildozer==$BUILDOZER_VERSION" "cython==$CYTHON_VERSION"
fi

REQS=$("$PY" -c "import PySide6,pathlib;print(pathlib.Path(PySide6.__file__).parent/'scripts'/'requirements-android.txt')")
if command -v uv >/dev/null; then
    uv pip install --python "$PY" -q -r "$REQS"
else
    "$PY" -m pip install -q -r "$REQS"
fi


# ---------------------------------------------------------------------------
# 2. Patch the deploy tool and buildozer
# ---------------------------------------------------------------------------
say "Applying workarounds"
SITE=$("$PY" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')
"$PY" "$HERE/patches/apply_patches.py" "$SITE"


# ---------------------------------------------------------------------------
# 3. Android wheels
# ---------------------------------------------------------------------------
say "Fetching PySide6 Android wheels ($ANDROID_ARCH)"
WHEEL_PYSIDE=$BUILD_DIR/pyside6-$PYSIDE_VERSION-$PYSIDE_VERSION-cp311-cp311-android_$ANDROID_ARCH.whl
WHEEL_SHIBOKEN=$BUILD_DIR/shiboken6-$PYSIDE_VERSION-$PYSIDE_VERSION-cp311-cp311-android_$ANDROID_ARCH.whl

[ -s "$WHEEL_PYSIDE" ] || curl -sSL --fail -o "$WHEEL_PYSIDE" \
    "$QT_DOWNLOADS/pyside6/$(basename "$WHEEL_PYSIDE")"
[ -s "$WHEEL_SHIBOKEN" ] || curl -sSL --fail -o "$WHEEL_SHIBOKEN" \
    "$QT_DOWNLOADS/shiboken6/$(basename "$WHEEL_SHIBOKEN")"


# ---------------------------------------------------------------------------
# 4. Android NDK
# ---------------------------------------------------------------------------
# download_android_ndk() in the deploy tool has no `return` statement, so it
# always yields None and the build dies with a TypeError. Fetch the NDK here
# and pass --ndk-path explicitly, which takes priority.
if [ ! -d "$NDK_DIR" ]; then
    say "Downloading Android NDK $NDK_VERSION (~650MB)"
    mkdir -p "$DEPLOY_CACHE/android-ndk"
    curl -sSL --fail -o "$DEPLOY_CACHE/android-ndk/ndk.zip" \
        "https://dl.google.com/android/repository/android-ndk-$NDK_VERSION-linux.zip"
    unzip -q "$DEPLOY_CACHE/android-ndk/ndk.zip" -d "$DEPLOY_CACHE/android-ndk"
    rm -f "$DEPLOY_CACHE/android-ndk/ndk.zip"
fi


# ---------------------------------------------------------------------------
# 5. Apache Ant
# ---------------------------------------------------------------------------
# buildozer skips its own (broken) download when the directory already exists.
if [ ! -d "$ANT_DIR" ]; then
    say "Installing Apache Ant $ANT_VERSION"
    mkdir -p "$BUILDOZER_PLATFORM"
    curl -sSL --fail -o "$BUILDOZER_PLATFORM/ant.tar.gz" \
        "https://archive.apache.org/dist/ant/binaries/apache-ant-$ANT_VERSION-bin.tar.gz"
    tar xzf "$BUILDOZER_PLATFORM/ant.tar.gz" -C "$BUILDOZER_PLATFORM"
    rm -f "$BUILDOZER_PLATFORM/ant.tar.gz"
fi


# ---------------------------------------------------------------------------
# 6. Android SDK + licences
# ---------------------------------------------------------------------------
# Bootstrap the SDK ourselves so licences are accepted up front. buildozer
# early-returns when android-sdk/ exists, so a partially downloaded directory
# from a failed run will silently poison every later build -- hence the
# unpack-then-move.
if [ ! -x "$SDK_DIR/tools/bin/sdkmanager" ]; then
    say "Installing Android SDK command-line tools"
    rm -rf "$SDK_DIR" "$SDK_DIR.tmp"
    mkdir -p "$SDK_DIR.tmp"
    curl -sSL --fail -o "$SDK_DIR.tmp/$CMDLINE_TOOLS" \
        "https://dl.google.com/android/repository/$CMDLINE_TOOLS"
    unzip -q "$SDK_DIR.tmp/$CMDLINE_TOOLS" -d "$SDK_DIR.tmp"
    rm -f "$SDK_DIR.tmp/$CMDLINE_TOOLS"
    mv "$SDK_DIR.tmp" "$SDK_DIR"
fi

if [ ! -d "$SDK_DIR/platform-tools" ]; then
    say "Accepting SDK licences and installing platform-tools"
    yes | "$SDK_DIR/tools/bin/sdkmanager" --sdk_root="$SDK_DIR" \
        "${SDKMANAGER_PROXY[@]}" --licenses >/dev/null || true
    yes | "$SDK_DIR/tools/bin/sdkmanager" --sdk_root="$SDK_DIR" \
        "${SDKMANAGER_PROXY[@]}" platform-tools >/dev/null
fi


# ---------------------------------------------------------------------------
# 7. Build
# ---------------------------------------------------------------------------
say "Building APK (this takes 10-20 minutes; CPython is cross-compiled)"

cp "$HERE/app/main.py" "$BUILD_DIR/main.py"   # entry point MUST be main.py
rm -f "$BUILD_DIR/pysidedeploy.spec"          # stale spec skips NDK resolution

cd "$BUILD_DIR"
PATH="$VENV/bin:$PATH" "$VENV/bin/pyside6-android-deploy" \
    --wheel-pyside "$WHEEL_PYSIDE" \
    --wheel-shiboken "$WHEEL_SHIBOKEN" \
    --ndk-path "$NDK_DIR" \
    --name "$APP_NAME" \
    -f -v

say "Done"
ls -la "$BUILD_DIR"/*.apk
