// https://stackoverflow.com/questions/49043257/how-to-ensure-to-run-some-code-on-same-background-thread/49075382#49075382
class Worker {
  public typealias Job = () -> Void

  private let semaphore = DispatchSemaphore(value: 0)
  private let lock = NSRecursiveLock()
  private var thread: Thread!
  private var queue = [Job]()
  private var canceled: Bool = false

  init() {
    thread = Thread(block: loop)
    thread.start()
  }

  public func cancel() {
    signalCancel()
    thread.cancel()
  }

  public func enqueue(_ job: @escaping Job) {
    locked {
      queue.append(job)
    }

    semaphore.signal()
  }

  /// gerdTV patch: runs [job] on the worker and waits for it (at most 2 s, so a busy worker can't hang the caller).
  public func sync(_ job: @escaping Job) {
    let done = DispatchSemaphore(value: 0)
    enqueue {
      job()
      done.signal()
    }
    _ = done.wait(timeout: .now() + 2)
  }

  private func loop() {
    while true {
      semaphore.wait()

      if isCanceled() {
        return
      }

      let job = getFirstJob()
      job()
    }
  }

  private func signalCancel() {
    locked {
      canceled = true
    }

    semaphore.signal()
  }

  private func isCanceled() -> Bool {
    let c = locked {
      canceled
    }

    return c
  }

  private func getFirstJob() -> Job {
    let job = locked {
      queue.removeFirst()
    }

    return job
  }

  private func locked<T>(do block: () -> T) -> T {
    lock.lock()
    defer {
      lock.unlock()
    }

    return block()
  }
}
