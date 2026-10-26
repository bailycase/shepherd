import Testing
import ShepherdUI

@Suite("Render probe", .serialized)
struct RenderProbeTests {
    @Test func concurrentLayoutMeasurementsAreCountedWithoutAnActorHop() async {
        SHRenderProbe.start()
        defer { SHRenderProbe.stop() }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<128 {
                group.addTask { SHRenderProbe.tick("layout.background") }
            }
        }
        #if DEBUG
        #expect(SHRenderProbe.count("layout.background") == 128)
        #else
        #expect(SHRenderProbe.count("layout.background") == 0)
        #endif
        let stopped = SHRenderProbe.stop()
        SHRenderProbe.tick("layout.background")
        #expect(SHRenderProbe.counts == stopped)
    }
}
