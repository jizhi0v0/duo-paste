import Testing
@testable import DuoPasteSync

/// Starts a worker and waits on its observable tick fence instead of assuming that a fixed sleep
/// means the actor has run. `ticks=2` covers a scripted `has_more` second page; full-mirror tests can
/// additionally wait for detached blob hydration.
func runPullWorkerToCompletion(
    _ worker: PullWorker,
    ticks: UInt64 = 1,
    includingBlobHydration: Bool = false,
    timeoutSec: Double = 10
) async {
    let baseline = await worker.completedTickCountForTesting()
    await worker.start()
    let completed = await worker.waitForCompletedTicksForTesting(
        atLeast: baseline + max(1, ticks),
        includingBlobHydration: includingBlobHydration,
        timeoutSec: timeoutSec
    )
    if !completed {
        Issue.record("PullWorker did not complete \(ticks) tick(s) within \(timeoutSec)s")
    }
    await worker.stop()
}
