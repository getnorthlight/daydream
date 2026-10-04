#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
out="$PWD/BackupRestore/.build/native"
mkdir -p "$out"
compile() { swiftc -module-cache-path "$out/cache" -I "$out" -I Sources/CSQLite -L "$out" -Xlinker -rpath -Xlinker "$out" "$@"; }
compile -emit-library -emit-module -enable-testing -module-name HistoryCore Sources/HistoryCore/*.swift -o "$out/libHistoryCore.dylib" -emit-module-path "$out/HistoryCore.swiftmodule"
compile -emit-library -emit-module -enable-testing -module-name MemoryCore Sources/MemoryCore/*.swift -lHistoryCore -o "$out/libMemoryCore.dylib" -emit-module-path "$out/MemoryCore.swiftmodule"
compile -emit-library -emit-module -enable-testing -module-name BackupRestore BackupRestore/Native/*.swift -lMemoryCore -lHistoryCore -o "$out/libBackupRestore.dylib" -emit-module-path "$out/BackupRestore.swiftmodule"
compile BackupRestore/Worker/main.swift -lBackupRestore -lMemoryCore -lHistoryCore -o "$out/mac-mem-backup"
compile -parse-as-library BackupRestore/Tests/NativeChecks.swift -lBackupRestore -lMemoryCore -lHistoryCore -o "$out/backup-checks"
compile Sources/MacMemCLI/main.swift -lMemoryCore -lHistoryCore -o "$out/mac-mem"
"$out/backup-checks" "$out/mac-mem-backup"
