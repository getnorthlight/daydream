// Prints the Unix time Foundation reads (Date()). wb-core-clock-checks.sh runs it under scripts/clock-shift.c before
// each shifted run of wb-core, so a shift that didn't take is a failure, not a pass at the real time.
import Foundation
print(Int(Date().timeIntervalSince1970))
