"""Collect pinned source/license/build references without running build scripts.

This review kit is deliberately marked incomplete until vendor binary dependency
closure is established. It does not assert GPL compliance or release permission.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import tarfile

PIN = "98ce13b5f05b68ff280b2e4b463c9a0f3be303d2c83a1e18ffbddf90f2b19ad1"

def prepare(archive, output):
    if hashlib.sha256(archive.read_bytes()).hexdigest() != PIN:
        raise ValueError("Typesense source archive pin mismatch")
    if output.exists():
        raise ValueError("Fresh output required")
    output.mkdir(mode=0o700)
    shutil.copyfile(archive, output / "typesense-v30.2-source.tar.gz")
    references = []
    with tarfile.open(archive, "r:gz") as source:
        license_data = source.extractfile("typesense-30.2/LICENSE.txt").read()
        (output / "Typesense-LICENSE.txt").write_bytes(license_data)
        for member in source.getmembers():
            name = member.name.removeprefix("typesense-30.2/")
            if not member.isfile() or member.size > 2_000_000:
                continue
            if not (name.startswith(("cmake/", "bazel/", "docker/")) or name.endswith((".bzl", ".bazel", ".sh"))
                    or name in ("WORKSPACE", "MODULE.bazel", "CMakeLists.txt")):
                continue
            text = source.extractfile(member).read().decode("utf-8", errors="replace")
            for number, line in enumerate(text.splitlines(), 1):
                if any(word in line for word in ("https://", "http://", "FIND_PACKAGE", "find_package", "brew install", "git clone", "GIT_TAG")):
                    references.append({"sourceFile": name, "line": number, "text": line.strip()})
    (output / "dependency-source-references.json").write_text(json.dumps(references, indent=2) + "\n")
    (output / "Typesense-NOTICES.txt").write_text(
        "Typesense 30.2. Copyright notices are retained in the accompanying unmodified source archive.\n"
        "Licensed under GNU GPL version 3; full license is Typesense-LICENSE.txt. No warranty is provided under that license.\n"
        "Source: https://github.com/typesense/typesense/tree/v30.2\n"
        "Accompanying source archive: typesense-v30.2-source.tar.gz\n"
        "This source-materials review kit is NOT YET a complete corresponding-source distribution.\n"
        "The vendor ARM64 binary includes statically linked dependencies. Their exact release-build versions, complete source and notices remain to be bound to that binary.\n"
        "Do not distribute the binary with this notice as an assertion that those obligations are satisfied.\n")
    (output / "DELIVERY-REVIEW.md").write_text(
        "# Typesense source delivery review\n\n"
        "Prepared official v30.2 source archive, full GPLv3 license, notice draft and source-located dependency/build references. No build scripts executed.\n\n"
        "Proposed delivery: place the verified complete corresponding-source kit beside the binary delivery at no additional charge, with a relative Source/ link in the delivered notice. Keep the source available with the binary; do not invent a written offer or external hosting promise.\n\n"
        "Concrete unresolved technical scope: CMakeLists.txt explicitly selects static .a dependencies and finds OpenSSL, Snappy, ZLIB, CURL, ICU, Protobuf, LevelDB, gflags and glog without binding all versions. Included cmake/Bazel scripts reference further ONNX, RocksDB, H2O, iconv, kakasi, s2 and other sources/patches. dependency-source-references.json records exact locations; the full build files and bundled header notices remain in the source archive. System-only otool output cannot establish static-library source closure.\n\n"
        "Need vendor build provenance for the pinned darwin-arm64 binary or an independently reviewed rebuild/source closure. Do not substitute a rebuild under the current binary pin. The upstream tar contains only executable and MD5, not these materials.\n\n"
        "Legal review needed: whether the app/server combination is an aggregate and whether proposed source delivery satisfies the applicable GPLv3 conveying provisions. Packaging cannot establish that from a separate-process boundary alone. This kit does not authorize release.\n")
    hashes = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in output.iterdir() if p.is_file()}
    (output / "source-materials-manifest.json").write_text(json.dumps({"completeCorrespondingSource": False,
        "sourceURL": "https://codeload.github.com/typesense/typesense/tar.gz/refs/tags/v30.2", "files": hashes}, indent=2) + "\n")
    print(output / "source-materials-manifest.json")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    prepare(args.archive, args.output)
