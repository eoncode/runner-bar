// RunnerState.swift
// RunnerBarCore

import Foundation
import Observation

@Observable @MainActor
public final class RunnerState {
    public var runners: [Runner] = []
    public var jobs: [ActiveJob] = []
    public var actions: [WorkflowActionGroup] = []
    public var isRateLimited = false
    public var rateLimitResetDate: Date?
    public var fetchError: Error?
    public init() {}
}
