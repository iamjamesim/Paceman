import Foundation

@main struct WatchWorkTransitions {
    @MainActor static func main() async throws {
        let activation = WatchWorkActivation()
        // Already activated reads need no subsequent delegate callback.
        try await activation.wait(activated: true, timeout: .zero)

        let callback = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(20))
            activation.complete(.success(()))
        }
        async let first: Void = activation.wait(activated: false, timeout: .seconds(1))
        async let second: Void = activation.wait(activated: false, timeout: .seconds(1))
        _ = try await (first, second, callback.value)
        // A duplicate callback and a cancelled deadline cannot resume twice.
        activation.complete(.success(()))

        do {
            try await activation.wait(activated: false, timeout: .milliseconds(1))
            preconditionFailure("Activation must have a bounded deadline")
        } catch is WatchWorkActivation.ActivationError {}
        activation.complete(.success(()))

        let cancelled = Task { @MainActor in
            try await activation.wait(activated: false, timeout: .seconds(1))
        }
        cancelled.cancel()
        do {
            try await cancelled.value
            preconditionFailure("Cancelled reads must not keep waiting")
        } catch is CancellationError {}

        let suspended = Task { @MainActor in
            try await activation.wait(activated: false, timeout: .seconds(1))
        }
        try await Task.sleep(for: .milliseconds(20))
        suspended.cancel()
        do {
            try await suspended.value
            preconditionFailure("Backgrounding must release an activation waiter")
        } catch is CancellationError {}
        activation.complete(.success(()))

        let failure = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(20))
            activation.complete(.failure(CancellationError()))
        }
        do {
            try await activation.wait(activated: false, timeout: .seconds(1))
            preconditionFailure("Delegate failure must reach the waiting read")
        } catch is CancellationError {}
        try await failure.value

        // A timed-out or cancelled read cannot poison the next activation.
        let recovery = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(20))
            activation.complete(.success(()))
        }
        try await activation.wait(activated: false, timeout: .seconds(1))
        try await recovery.value
        print("watch work transitions passed")
    }
}
