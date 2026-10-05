#!/usr/bin/env python3

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import urllib.request
import zipfile


ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "https://github.com/ghostty-org/ghostty.git"
FRAMEWORK = Path("GhosttyKit.xcframework")
LIBRARY = Path("macos-arm64/libghostty-internal.a")
HEADERS = Path("macos-arm64/Headers")


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run(*args, cwd=None, capture=False, env=None):
    result = subprocess.run(
        [str(arg) for arg in args], cwd=cwd, env=env, check=True,
        text=True, stdout=subprocess.PIPE if capture else None,
    )
    return result.stdout.strip() if capture else None


def source_versions(source):
    metadata = (source / "build.zig.zon").read_text()
    version = re.search(r'^\s*\.version\s*=\s*"(\d+\.\d+\.\d+)(?:-[^"]+)?"', metadata, re.MULTILINE)
    zig = re.search(r'^\s*\.minimum_zig_version\s*=\s*"(\d+\.\d+\.\d+)"', metadata, re.MULTILINE)
    require(version and zig, "source must declare its app version and a released Zig version")
    return version[1], zig[1]


def zig_distribution(version):
    with urllib.request.urlopen("https://ziglang.org/download/index.json", timeout=60) as response:
        release = json.load(response).get(version, {}).get("aarch64-macos", {})
    url = f"https://ziglang.org/download/{version}/zig-aarch64-macos-{version}.tar.xz"
    require(release.get("tarball") == url, f"official arm64 macOS Zig {version} distribution is unavailable")
    digest = release.get("shasum", "")
    require(isinstance(digest, str) and re.fullmatch(r"[0-9a-f]{64}", digest), "invalid official Zig SHA-256")
    return {"version": version, "url": url, "sha256": digest}


def verify_hash(path, expected):
    require(sha256(path) == expected, f"SHA-256 mismatch: {path}")


def install_zig(pin, output, cache):
    archive = cache / pin["url"].rsplit("/", 1)[1]
    if not archive.exists():
        partial = output / "zig-download.tar.xz"
        with urllib.request.urlopen(pin["url"], timeout=60) as response, partial.open("xb") as stream:
            shutil.copyfileobj(response, stream)
        verify_hash(partial, pin["sha256"])
        partial.rename(archive)
    verify_hash(archive, pin["sha256"])
    destination = output / "zig"
    destination.mkdir()
    run("tar", "-xJf", archive, "-C", destination, "--strip-components=1")
    return destination / "zig"


def verify_source(source, revision):
    require(run("git", "rev-parse", "HEAD", cwd=source, capture=True) == revision, "source revision mismatch")
    require(not run("git", "status", "--porcelain", "--untracked-files=all", cwd=source, capture=True), "source checkout is dirty")


def build_flags():
    return [
        "-Doptimize=ReleaseFast",
        "-Demit-macos-app=false",
        "-Dxcframework-target=native",
    ]


def embedded_version(archive, expected):
    found = False
    with subprocess.Popen(["strings", str(archive)], stdout=subprocess.PIPE, text=True) as process:
        for line in process.stdout:
            found = found or line.strip() == expected
        require(process.wait() == 0, "could not inspect the archive version")
    require(found, f"archive does not contain the expected source version: {expected}")
    return expected


def verify_framework(framework, source):
    with (framework / "Info.plist").open("rb") as stream:
        libraries = plistlib.load(stream).get("AvailableLibraries", [])
    require(len(libraries) == 1, "framework must contain exactly one library")
    library = libraries[0]
    require(
        library.get("LibraryIdentifier") == "macos-arm64"
        and library.get("LibraryPath") == LIBRARY.name
        and library.get("HeadersPath") == "Headers"
        and library.get("SupportedArchitectures") == ["arm64"]
        and library.get("SupportedPlatform") == "macos",
        "framework must contain the native arm64 macOS static library",
    )
    expected = {Path("Info.plist"), LIBRARY, HEADERS / "ghostty.h", HEADERS / "module.modulemap"}
    actual = {path.relative_to(framework) for path in framework.rglob("*") if path.is_file()}
    require(actual == expected, "unexpected framework contents")
    require(not any(path.is_symlink() for path in framework.rglob("*")), "framework must not contain symlinks")
    require(run("lipo", "-archs", framework / LIBRARY, capture=True) == "arm64", "archive must be arm64-only")
    for name in ("ghostty.h", "module.modulemap"):
        require(
            (framework / HEADERS / name).read_bytes() == (source / "include" / name).read_bytes(),
            f"framework header differs from pinned source: {name}",
        )
    return {str(path): sha256(framework / path) for path in sorted(expected)}


def package_framework(framework, archive, hashes):
    with zipfile.ZipFile(archive, "x", compression=zipfile.ZIP_DEFLATED) as package:
        for relative, expected in sorted(hashes.items()):
            source = framework / relative
            verify_hash(source, expected)
            package.write(source, str(FRAMEWORK / relative))
    return sha256(archive)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Build current upstream Ghostty main at one immutable revision without changing installed dependencies.")
    parser.add_argument("--output-dir", type=Path, default=ROOT / ".build/ghosttykit-source", help="new directory for source, tools and candidate artifacts")
    parser.add_argument("--cache-dir", type=Path, default=ROOT / ".build/ghosttykit-cache")
    parser.add_argument("--zig", type=Path, help="existing Zig executable; must match the source's required version")
    args = parser.parse_args(argv)
    require(platform.system() == "Darwin" and platform.machine() == "arm64", "an arm64 macOS host is required")
    require(shutil.which("msgfmt"), "gettext's msgfmt must be on PATH")
    run("xcrun", "-sdk", "macosx", "-find", "metal", capture=True)
    run("xcrun", "-sdk", "macosx", "-find", "metallib", capture=True)
    output = args.output_dir.resolve()
    require(not output.exists(), f"output directory already exists; choose a new path: {output}")
    output.mkdir(parents=True)
    cache = args.cache_dir.resolve()
    cache.mkdir(parents=True, exist_ok=True)
    remote = run("git", "ls-remote", REPOSITORY, "refs/heads/main", capture=True).split()
    require(len(remote) == 2 and remote[1] == "refs/heads/main" and re.fullmatch(r"[0-9a-f]{40}", remote[0]), "could not resolve upstream main to one commit")
    revision = remote[0]
    source = output / "source"
    run("git", "init", "--quiet", source)
    run("git", "remote", "add", "origin", REPOSITORY, cwd=source)
    run("git", "fetch", "--depth=1", "--no-tags", "origin", revision, cwd=source)
    run("git", "checkout", "--quiet", "-b", "main", "FETCH_HEAD", cwd=source)
    verify_source(source, revision)
    version, required_zig = source_versions(source)
    distribution = zig_distribution(required_zig)
    zig = args.zig.resolve() if args.zig else install_zig(distribution, output, cache)
    zig_version = run(zig, "version", capture=True)
    require(zig_version == required_zig, f"expected Zig {required_zig}, found {zig_version}")
    tools = {
        "zig_version": zig_version,
        "zig_executable_sha256": sha256(zig),
        "zig_distribution": {**distribution, "verified": not bool(args.zig)},
        "xcode": run("xcodebuild", "-version", capture=True),
        "sdk_version": run("xcrun", "-sdk", "macosx", "--show-sdk-version", capture=True),
        "sdk_build": run("xcrun", "-sdk", "macosx", "--show-sdk-build-version", capture=True),
        "macos": run("sw_vers", "-productVersion", capture=True),
        "macos_build": run("sw_vers", "-buildVersion", capture=True),
        "architecture": platform.machine(),
        "gettext": run("msgfmt", "--version", capture=True).splitlines()[0],
    }
    flags = build_flags()
    environment = {
        **os.environ,
        "ZIG_LIB_DIR": str(zig.parent / "lib"),
        "ZIG_LOCAL_CACHE_DIR": str(cache / "local"),
        "ZIG_GLOBAL_CACHE_DIR": str(cache / "global"),
    }
    print(f"Building Ghostty {revision} with Zig {zig_version}", flush=True)
    run(zig, "build", *flags, cwd=source, env=environment)
    verify_source(source, revision)
    framework = source / "macos/GhosttyKit.xcframework"
    hashes = verify_framework(framework, source)
    short_revision = run("git", "log", "--format=%h", "-1", cwd=source, capture=True)
    version = embedded_version(framework / LIBRARY, f"{version}-main+{short_revision}")
    archive = output / "GhosttyKit.xcframework.zip"
    archive_hash = package_framework(framework, archive, hashes)
    provenance = {
        "schema_version": 1,
        "source_repository": REPOSITORY,
        "source_revision": revision,
        "source_version": version,
        "source_clean": True,
        "zig_version": zig_version,
        "tools": tools,
        "build_arguments": ["build", *flags],
        "framework_files": hashes,
        "framework": str(FRAMEWORK),
        "zip": archive.name,
        "zip_sha256": archive_hash,
        "builder_sha256": sha256(Path(__file__)),
    }
    manifest = output / "provenance.json"
    manifest.write_text(json.dumps(provenance, indent=2, sort_keys=True) + "\n")
    print(f"Candidate ZIP: {archive}\nSHA-256: {archive_hash}\nProvenance: {manifest}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"ghosttykit-build: {error}", file=sys.stderr)
        sys.exit(1)
