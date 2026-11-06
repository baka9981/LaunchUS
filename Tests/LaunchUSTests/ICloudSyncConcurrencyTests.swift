import Dispatch
import Testing
@testable import LaunchUS

extension AutoBackupTests {
    // Run with `swift test --sanitize=thread --filter remoteApplyFlagCanBeReadWhileItChanges`.
    // LayoutStore may save from a background task while the main actor applies
    // a remote layout. Access to this suppression flag must be synchronized.
    @Test func remoteApplyFlagCanBeReadWhileItChanges() {
        let previous = ICloudSync.applying
        defer { ICloudSync.applying = previous }
        DispatchQueue.concurrentPerform(iterations: 5_000) { index in
            if index.isMultiple(of: 2) {
                ICloudSync.applying = index.isMultiple(of: 4)
            } else {
                _ = ICloudSync.applying
            }
        }
        ICloudSync.applying = true
        #expect(ICloudSync.applying)
    }
}
