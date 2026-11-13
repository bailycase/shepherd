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

    @Test func unitsOfWorkAreAddedOnlyWhileRecording() {
        var evaluated = 0
        func amount() -> Int { evaluated += 1; return 40 }
        SHRenderProbe.add("code.styledUnits", amount())
        #expect(evaluated == 0 && SHRenderProbe.count("code.styledUnits") == 0, "nothing is counted, or worked out, while idle")
        SHRenderProbe.start()
        defer { SHRenderProbe.stop() }
        SHRenderProbe.add("code.styledUnits", amount())
        SHRenderProbe.add("code.styledUnits", 2)
        #if DEBUG
        #expect(SHRenderProbe.count("code.styledUnits") == 42 && evaluated == 1)
        #else
        #expect(SHRenderProbe.count("code.styledUnits") == 0)
        #endif
    }
}
