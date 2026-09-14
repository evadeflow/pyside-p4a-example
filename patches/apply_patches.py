#!/usr/bin/env python3
"""
Patch the PySide6 Android deploy tool and buildozer so a PySide6 6.11.2
application can actually be packaged into an APK.

pyside6-android-deploy is a technical preview that drives buildozer, which in
turn drives a Qt fork of python-for-android that was never merged upstream.
Several defects in that chain stop the build outright. Each patch below is
applied to the *build virtualenv only* -- nothing outside it is touched.

Run as:

    python3 patches/apply_patches.py <path-to-site-packages>

Idempotent: every patch is skipped if it is already present.
"""

import os
import shutil
import sys
import tempfile
from pathlib import Path

MARKER = "PATCHED-BY-PYSIDE-P4A-EXAMPLE"

# The newest python-for-android `develop` commit whose python3 recipe is still
# 3.11.13 and which already carries the `qt` bootstrap.
P4A_COMMIT = "3762c88c56e3443efb8eba2a02a2604b680240fd"


def write_breaking_hardlinks(path: Path, text: str) -> None:
    """
    Replace `path`'s contents without writing through a hardlink.

    uv installs packages by hardlinking files out of its shared cache
    (~/.cache/uv/archive-v0/...), so a file in a virtualenv is frequently the
    *same inode* as the cached copy. Truncating it in place -- which is what
    open(path, "w") and Path.write_text do -- edits the cache as well, and
    every future `uv pip install` of that package on this machine then hands
    out the patched file. That is a silent, machine-wide side effect.

    Writing a temporary file and renaming it over the target creates a fresh
    inode, leaving the cached copy untouched.
    """
    with tempfile.NamedTemporaryFile(
        "w", dir=path.parent, prefix=path.name + ".", suffix=".tmp", delete=False
    ) as handle:
        handle.write(text)
        tmp = Path(handle.name)

    shutil.copymode(path, tmp)
    os.replace(tmp, path)


def patch(path: Path, old: str, new: str, label: str) -> None:
    text = path.read_text()

    if MARKER in text and label in text:
        print(f"  = {label}: already applied")
        return

    count = text.count(old)
    if count != 1:
        raise SystemExit(
            f"  ! {label}: anchor text found {count} times in {path}, expected 1.\n"
            f"    The upstream source has changed; re-check this patch."
        )

    write_breaking_hardlinks(path, text.replace(old, new))
    print(f"  + {label}: applied")


def patch_p4a_commit(site: Path) -> None:
    """
    p4a's `develop` branch now builds CPython 3.14, but the PySide6 and
    shiboken6 Android wheels are cp311 and link against libpython3.11.so.
    Without this pin the APK builds fine and then dies at startup with:

        dlopen failed: library "libpython3.11.so" not found:
          needed by libshiboken6.abi3.so

    buildozer supports a `p4a.commit` key, so pin the last 3.11 commit.
    """
    patch(
        site / "PySide6/scripts/deploy_lib/android/buildozer.py",
        '        self.set_value("app", "p4a.branch", "develop")',
        '        self.set_value("app", "p4a.branch", "develop")\n'
        f'        # {MARKER}: p4a-commit-pin\n'
        '        # p4a develop builds CPython 3.14; the PySide6/shiboken6 Android\n'
        '        # wheels are cp311 and need libpython3.11.so at dlopen time.\n'
        f'        self.set_value("app", "p4a.commit", "{P4A_COMMIT}")',
        "p4a-commit-pin",
    )


def patch_orientation(site: Path) -> None:
    """
    buildozer defaults to portrait with the system bars visible, which
    letterboxes the app with black bars on a landscape tablet.

    Valid `orientation` values are only landscape, portrait, landscape-reverse
    and portrait-reverse -- buildozer rejects anything else (e.g.
    "sensorLandscape") during spec validation.
    """
    patch(
        site / "PySide6/scripts/deploy_lib/android/buildozer.py",
        '        self.set_value("app", "p4a.bootstrap", "qt")',
        '        self.set_value("app", "p4a.bootstrap", "qt")\n'
        f'        # {MARKER}: orientation-fullscreen\n'
        '        self.set_value("app", "orientation", "landscape")\n'
        '        self.set_value("app", "fullscreen", "1")',
        "orientation-fullscreen",
    )


def patch_buildozer_download(site: Path) -> None:
    """
    buildozer downloads Apache Ant and the Android command-line tools with
    urllib.request.urlretrieve, which fails here with:

        ValueError: read of closed file

    curl fetches the same URLs without complaint, so use it instead. This also
    makes buildozer honour http_proxy/https_proxy for these downloads.
    """
    patch(
        site / "buildozer/__init__.py",
        "        self.debug('Downloading {0}'.format(url))\n"
        "        urlretrieve(url, filename, report_hook)\n"
        "        return filename",
        "        self.debug('Downloading {0}'.format(url))\n"
        f"        # {MARKER}: buildozer-download-curl\n"
        "        import subprocess as _sp\n"
        "        _sp.check_call(\n"
        "            ['curl', '-sSL', '--retry', '3', '--fail', '-o', filename, url]\n"
        "        )\n"
        "        return filename",
        "buildozer-download-curl",
    )


def patch_sdkmanager_proxy(site: Path) -> None:
    """
    The JVM does not read http_proxy/https_proxy, so on a machine whose only
    egress is an HTTP proxy every sdkmanager call fails with

        java.net.UnknownHostException: dl.google.com

    even though curl reaches the same host. sdkmanager has its own proxy flags;
    pass them through when a proxy is configured. No-op without one.
    """
    patch(
        site / "buildozer/targets/android.py",
        '        command = [self.sdkmanager_path, f"--sdk_root={android_sdk_dir}", *args]',
        '        command = [self.sdkmanager_path, f"--sdk_root={android_sdk_dir}", *args]\n'
        f'        # {MARKER}: sdkmanager-proxy\n'
        '        import os as _os\n'
        '        from urllib.parse import urlparse as _urlparse\n'
        '        _px = _os.environ.get("https_proxy") or _os.environ.get("http_proxy")\n'
        '        if _px:\n'
        '            _u = _urlparse(_px)\n'
        '            command += [\n'
        '                "--proxy=http",\n'
        '                f"--proxy_host={_u.hostname}",\n'
        '                f"--proxy_port={_u.port or 80}",\n'
        '            ]',
        "sdkmanager-proxy",
    )


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)

    site = Path(sys.argv[1]).resolve()
    if not (site / "PySide6").is_dir():
        raise SystemExit(f"{site} does not look like a site-packages with PySide6 in it")

    print(f"Patching {site}")
    patch_p4a_commit(site)
    patch_orientation(site)
    patch_buildozer_download(site)
    patch_sdkmanager_proxy(site)
    print("Done.")


if __name__ == "__main__":
    main()
