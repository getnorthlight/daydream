"""Build the seven macOS 15 llama.cpp libraries with the PROVENANCE.md recipe. Local only.

No downloads, no signing, no install. Takes an already extracted and checked
source folder `llama.cpp-<commit>` and the CMake 3.31.6 binary, and writes into
a fresh folder:

  build/            the CMake build tree (with compile_commands.json)
  build.log         configure and build output
  runtime/          the seven libraries, unchanged from the build
  runtime-LICENSE   the llama.cpp MIT licence
  runtime.tar       the canonical archive (see macos15_runtime_archive.py)
  build-info.json   tools, flags and every SHA-256

`-ffile-prefix-map` rewrites the source and build folders to `llama.cpp` and
`build`, so the libraries do not depend on where the build ran. Two builds with
the same tools give byte-identical files. Check a result with
`python3 WriterBackend/audit_macos15_runtime.py <folder>`.
"""
import argparse
import hashlib
import json
import os
import pathlib
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from macos15_runtime_archive import LIBRARIES, archive_from_folder  # noqa: E402

COMMIT = "b14e3fb90ca8c760f4254ddc9aa7845ebbdb2edf"
CMAKE_VERSION = "cmake version 3.31.6"
VENDOR = pathlib.Path(__file__).resolve().parent / "Sources/CLlamaBridge/vendor"
HEADERS = {"LICENSE": "LICENSE", "llama.h": "include/llama.h", "gguf.h": "ggml/include/gguf.h",
           **{h: "ggml/include/" + h for h in ("ggml.h", "ggml-alloc.h", "ggml-backend.h", "ggml-cpu.h", "ggml-opt.h")}}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def require(ok, message):
    if not ok:
        raise SystemExit("build_macos15_runtime: " + message)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--cmake", type=pathlib.Path, required=True)
    parser.add_argument("--source", type=pathlib.Path, required=True, help="extracted llama.cpp-" + COMMIT)
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("out", type=pathlib.Path, help="fresh folder for the build and results")
    args = parser.parse_args()
    source, out, cmake = args.source.resolve(), args.out, args.cmake.resolve()
    require(out.is_absolute() and not out.exists() and out.parent.resolve() == out.parent, "fresh absolute output folder required")
    require(source.name == "llama.cpp-" + COMMIT and source.is_dir(), "source folder must be llama.cpp-" + COMMIT)
    require(not any(c.isspace() for c in str(source) + str(out)), "paths must not contain spaces")
    # The source must carry the exact headers the bridge was reviewed against.
    for vendored, upstream in HEADERS.items():
        require((VENDOR / vendored).read_bytes() == (source / upstream).read_bytes(), "source differs from tracked " + vendored)
    version = subprocess.check_output([str(cmake), "--version"], text=True).splitlines()[0]
    require(version == CMAKE_VERSION, "CMake 3.31.6 required, found " + version)

    build = out / "build"
    out.mkdir(mode=0o755)
    prefix_maps = f"-ffile-prefix-map={source}=llama.cpp -ffile-prefix-map={build}=build"
    flags = "-Werror=unguarded-availability-new " + prefix_maps
    configure = [str(cmake), "-S", str(source), "-B", str(build),
                 "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0",
                 "-DCMAKE_OSX_ARCHITECTURES=arm64", "-DCMAKE_INSTALL_RPATH=@loader_path",
                 "-DCMAKE_BUILD_WITH_INSTALL_RPATH=ON", "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON",
                 "-DGGML_METAL=ON", "-DGGML_METAL_EMBED_LIBRARY=ON", "-DGGML_RPC=ON", "-DGGML_NATIVE=OFF",
                 "-DLLAMA_BUILD_TESTS=OFF", "-DLLAMA_BUILD_EXAMPLES=OFF", "-DLLAMA_BUILD_TOOLS=OFF",
                 "-DLLAMA_BUILD_SERVER=OFF", "-DLLAMA_BUILD_COMMON=OFF", "-DLLAMA_BUILD_APP=OFF",
                 "-DLLAMA_BUILD_UI=OFF", "-DLLAMA_USE_PREBUILT_UI=OFF",
                 "-DLLAMA_BUILD_NUMBER=9723", "-DLLAMA_BUILD_COMMIT=" + COMMIT,
                 "-DCMAKE_C_FLAGS=" + flags, "-DCMAKE_CXX_FLAGS=" + flags]
    compile_ = [str(cmake), "--build", str(build), "--config", "Release", "-j", str(args.jobs)]
    # A small fixed environment: no inherited compiler flags, no git lookup above the source.
    env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": os.environ["HOME"], "LC_ALL": "C",
           "TMPDIR": os.environ.get("TMPDIR", "/tmp"), "ZERO_AR_DATE": "1",
           "GIT_CEILING_DIRECTORIES": str(source.parent)}
    with open(out / "build.log", "w") as log:
        for command in (configure, compile_):
            log.write("$ " + " ".join(command) + "\n")
            log.flush()
            subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT, env=env)

    runtime = out / "runtime"
    runtime.mkdir(mode=0o755)
    for name in LIBRARIES:
        built = (build / "bin" / name).resolve(strict=True)  # SOVERSION link -> the real library file
        require(built.parent == (build / "bin").resolve(), "unexpected library location " + str(built))
        (runtime / name).write_bytes(built.read_bytes())
        (runtime / name).chmod(0o755)
    (out / "runtime-LICENSE").write_bytes((source / "LICENSE").read_bytes())
    archive = archive_from_folder(out)
    (out / "runtime.tar").write_bytes(archive)

    tools = {"cmake": version,
             "clang": subprocess.check_output(["/usr/bin/xcrun", "clang", "--version"], text=True, env=env).splitlines()[0],
             "sdk": subprocess.check_output(["/usr/bin/xcrun", "--show-sdk-version"], text=True, env=env).strip()}
    info = {"sourceCommit": COMMIT, "tools": tools, "extraFlags": "-ffile-prefix-map=<source>=llama.cpp -ffile-prefix-map=<build>=build",
            "environment": {k: v for k, v in env.items() if k in ("LC_ALL", "ZERO_AR_DATE")},
            "files": [{"name": name, "bytes": (runtime / name).stat().st_size, "sha256": sha((runtime / name).read_bytes())}
                      for name in LIBRARIES],
            "runtimeLicenseSHA256": sha((out / "runtime-LICENSE").read_bytes()),
            "archive": {"name": "runtime.tar", "bytes": len(archive), "sha256": sha(archive)}}
    (out / "build-info.json").write_text(json.dumps(info, indent=2) + "\n")
    print(json.dumps(info, indent=2))


if __name__ == "__main__":
    main()
