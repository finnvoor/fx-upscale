import CoreMedia
import CoreVideo

// MARK: - FrameChannel

/// Ordered, bounded hand-off between a producer that submits async GPU work and
/// a consumer that appends results in submission order, letting decode, GPU
/// upscaling, and encoding overlap. The producer `enqueue`s a frame (blocking
/// at capacity) then `fulfill`s it from the GPU completion handler; the consumer
/// `dequeue`s and `wait`s for each. Either side can stop the other.
final class FrameChannel<Value> {
    // MARK: Lifecycle

    init(capacity: Int) { self.capacity = capacity }

    // MARK: Internal

    final class PendingFrame {
        init(time: CMTime) { self.time = time }

        let time: CMTime

        func wait() -> Value {
            ready.wait()
            return value!
        }

        func fulfill(_ value: Value) {
            self.value = value
            ready.signal()
        }

        private let ready = DispatchSemaphore(value: 0)
        private var value: Value?
    }

    @discardableResult func enqueue(_ frame: PendingFrame) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while queue.count >= capacity, !isAborted { condition.wait() }
        if isAborted { return false }
        queue.append(frame)
        condition.signal()
        return true
    }

    func dequeue() -> PendingFrame? {
        condition.lock()
        defer { condition.unlock() }
        while queue.isEmpty, !isFinished, !isAborted { condition.wait() }
        guard !queue.isEmpty else { return nil }
        condition.signal()
        return queue.removeFirst()
    }

    func finish(throwing error: Swift.Error? = nil) {
        condition.lock()
        defer { condition.unlock() }
        self.error = error
        isFinished = true
        condition.broadcast()
    }

    func abort() {
        condition.lock()
        defer { condition.unlock() }
        isAborted = true
        condition.broadcast()
    }

    var terminationError: Swift.Error? {
        condition.lock()
        defer { condition.unlock() }
        return error
    }

    // MARK: Private

    private let capacity: Int
    private let condition = NSCondition()
    private var queue: [PendingFrame] = []
    private var isFinished = false
    private var isAborted = false
    private var error: Swift.Error?
}
