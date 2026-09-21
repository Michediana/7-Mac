//
//  RateEstimate.swift
//  7-Mac
//
//  Throughput and time-remaining, from the byte counts the engine reports.
//
//  This is the payoff of `IProgress::SetCompleted` over parsing a percentage
//  out of a command line tool: real byte deltas over real time.
//

import Foundation

nonisolated struct RateEstimate {
    /// Samples closer together than this measure scheduling noise, not I/O.
    private static let minimumInterval: TimeInterval = 0.25
    /// Weight given to a new sample. Low, because throughput is spiky —
    /// a solid block decodes in a burst and then the disk catches up.
    private static let newSampleWeight = 0.25

    private var lastBytes: UInt64 = 0
    private var lastTime: Date?
    private(set) var bytesPerSecond: Double?

    mutating func record(_ completed: UInt64, at now: Date = .now) {
        guard let previous = lastTime else {
            lastTime = now
            lastBytes = completed
            return
        }
        let elapsed = now.timeIntervalSince(previous)
        guard elapsed >= Self.minimumInterval else { return }

        if completed < lastBytes {
            // A retry after a wrong password rewinds the counter; the old
            // average describes a run that is no longer happening.
            bytesPerSecond = nil
        } else {
            let sample = Double(completed - lastBytes) / elapsed
            bytesPerSecond = bytesPerSecond.map {
                $0 * (1 - Self.newSampleWeight) + sample * Self.newSampleWeight
            } ?? sample
        }
        lastBytes = completed
        lastTime = now
    }

    func secondsRemaining(completed: UInt64, total: UInt64) -> TimeInterval? {
        guard let rate = bytesPerSecond, rate > 0, total > completed else { return nil }
        return Double(total - completed) / rate
    }
}
