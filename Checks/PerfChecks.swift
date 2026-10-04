// Copyright (c) 2026 The DayDream Authors. Licensed under the MIT License;
// see LICENSE.

import Foundation
import MemoryCore

/// perf-1002: the typing proof's signature pass is reused only by the same launch and requirement, only briefly, and
/// never for a refusal.
func runPerfChecks() throws {
    var v = SignatureVerdicts()
    let s: UInt64 = 1_000_000_000
    let notes = "501:1790000000.25:com.apple.Notes|anchor apple"
    try check(!v.passed(notes, now: 10 * s), "perf: nothing is remembered before a check")
    v.record(notes, valid: true, now: 10 * s)
    try check(v.passed(notes, now: 10 * s) && v.passed(notes, now: 11 * s) && v.passed(notes, now: 12 * s),
              "perf: a pass is reused by the same launch within 2 s")
    try check(!v.passed(notes, now: 12 * s + 1), "perf: a pass older than 2 s checks again")
    try check(!v.passed(notes, now: 9 * s), "perf: a clock that went back checks again")
    try check(!v.passed("501:1790000099.5:com.apple.Notes|anchor apple", now: 11 * s), "perf: a reused PID (another start time) checks again")
    try check(!v.passed("501:1790000000.25:com.example.Notes|anchor apple", now: 11 * s), "perf: another bundle checks again")
    try check(!v.passed("501:1790000000.25:com.apple.Notes|anchor apple generic", now: 11 * s), "perf: another requirement checks again")
    v.record(notes, valid: false, now: 11 * s)
    try check(!v.passed(notes, now: 11 * s), "perf: a refusal drops the pass and is never remembered")
    for i in 0..<(SignatureVerdicts.capacity * 3) { v.record("p\(i)", valid: true, now: 20 * s) }
    try check(v.count <= SignatureVerdicts.capacity, "perf: the remembered passes stay bounded")
}
