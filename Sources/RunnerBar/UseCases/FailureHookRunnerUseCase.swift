// FailureHookRunnerUseCase.swift
// RunnerBar
import RunnerBarCore

// MARK: - FailureHookRunnerUseCase (shim)

/// All business logic lives in `RunnerBarCore.FailureHookRunnerUseCase`.
/// This typealias keeps the name visible inside the RunnerBar target without
/// duplicating any code.
typealias FailureHookRunnerUseCase = RunnerBarCore.FailureHookRunnerUseCase
