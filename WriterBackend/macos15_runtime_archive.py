"""The canonical archive behind MacOS15Runtime.archiveSHA256.

The hash covers exactly eight files: the seven unsigned libraries in `runtime/`
and the llama.cpp MIT licence as `runtime-LICENSE`. They are packed as an
uncompressed POSIX ustar archive with fixed metadata (mtime 0, uid/gid 0, no
owner names, mode 0755 for the directory and libraries, 0644 for the licence)
in this order: `runtime/`, `runtime-LICENSE`, then the libraries by name.
Nothing about the build folder, the clock or the user ends up in the bytes, so
the same eight files always give the same archive and the same SHA-256.
"""
import hashlib
import io
import pathlib
import tarfile

LIBRARIES = (
    "libggml-base.0.dylib", "libggml-blas.0.dylib", "libggml-cpu.0.dylib",
    "libggml-metal.0.dylib", "libggml-rpc.0.dylib", "libggml.0.dylib", "libllama.0.dylib",
)
LICENSE_SHA256 = "94f29bbed6a22c35b992c5c6ebf0e7c92f13b836b90f36f461c9cf2f0f1d010d"


def _info(name, kind, size, mode):
    info = tarfile.TarInfo(name)
    info.type, info.size, info.mode = kind, size, mode
    info.mtime, info.uid, info.gid, info.uname, info.gname = 0, 0, 0, "", ""
    return info


def canonical_archive(files):
    """files: {"runtime-LICENSE": bytes, "<library>": bytes for all seven}. Returns the archive bytes."""
    if set(files) != {"runtime-LICENSE", *LIBRARIES}:
        raise ValueError("Exactly the licence and the seven libraries are required")
    if hashlib.sha256(files["runtime-LICENSE"]).hexdigest() != LICENSE_SHA256:
        raise ValueError("Licence pin mismatch")
    out = io.BytesIO()
    with tarfile.open(fileobj=out, mode="w", format=tarfile.USTAR_FORMAT) as tar:
        tar.addfile(_info("runtime", tarfile.DIRTYPE, 0, 0o755))
        tar.addfile(_info("runtime-LICENSE", tarfile.REGTYPE, len(files["runtime-LICENSE"]), 0o644),
                    io.BytesIO(files["runtime-LICENSE"]))
        for name in sorted(LIBRARIES):
            tar.addfile(_info("runtime/" + name, tarfile.REGTYPE, len(files[name]), 0o755), io.BytesIO(files[name]))
    return out.getvalue()


def archive_from_folder(root):
    """Canonical archive for <root>/runtime/<seven libraries> and <root>/runtime-LICENSE. Refuses links and extras."""
    root = pathlib.Path(root)
    runtime = root / "runtime"
    if runtime.is_symlink() or not runtime.is_dir() or {p.name for p in runtime.iterdir()} != set(LIBRARIES):
        raise ValueError("runtime/ must hold exactly the seven libraries")
    paths = {name: runtime / name for name in LIBRARIES}
    paths["runtime-LICENSE"] = root / "runtime-LICENSE"
    for path in paths.values():
        if path.is_symlink() or not path.is_file():
            raise ValueError("Regular files only: " + path.name)
    return canonical_archive({name: path.read_bytes() for name, path in paths.items()})
