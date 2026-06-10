// RingBuffer.swift
// RunnerBar
import Foundation

// MARK: - RingBuffer
/// Fixed-capacity circular buffer whose `values` property returns elements oldest-first.
struct RingBuffer {
    /// Backing array storing samples in insertion order (index 0 = oldest).
    private var storage: [Double]

    /// Creates a new ring buffer pre-filled with `fill`.
    /// - Parameters:
    ///   - capacity: Number of slots in the buffer.
    ///   - fill: Initial value for every slot (default `0`).
    init(capacity: Int, fill: Double = 0) {
        self.storage = Array(repeating: fill, count: capacity)
    }

    /// Drops the oldest element and appends `value` at the tail.
    /// - Parameter value: The new sample to insert.
    mutating func append(_ value: Double) {
        storage.removeFirst()
        storage.append(value)
    }

    /// Elements in insertion order, oldest first.
    var values: [Double] { storage }
}
