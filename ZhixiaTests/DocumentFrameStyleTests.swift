import SwiftUI
import Testing
@testable import Zhixia

/// US2（spec/live-edge-crop，plan D4/D6，FR-003）：文档模式整框样式的纯数据断言——
/// 实线性质（dash 恒空，类型不变量）、两态差异（锁定粗于跟踪、双线/单线结构）、
/// idCard 守卫（证件模式不消费文档整框样式）。样式可测面全部落在字段上，
/// 渲染断言不依赖快照测试基建。
struct DocumentFrameStyleTests {
    @Test("Both states draw continuous solid lines: dash is always empty")
    func dashAlwaysEmpty() {
        // 类型不变量（FR-003）：两态的面线与暗描边 dash 均为空——
        // 旧虚线 [8, 6] 已被连续实线替换，且本类型无任何虚线入口。
        #expect(DocumentFrameStyle.tracking.strokeStyle.dash.isEmpty)
        #expect(DocumentFrameStyle.locked.strokeStyle.dash.isEmpty)
        #expect(DocumentFrameStyle.locked.outlineStyle.dash.isEmpty)
    }

    @Test("Tracking is a thin single line; locked is a thicker double line")
    func lockedIsThickerDoubleLine() {
        let tracking = DocumentFrameStyle.tracking
        let locked = DocumentFrameStyle.locked

        // 结构差异：跟踪单线（无暗描边）；锁定双线（暗描边 + 白面线，与角括号同风格）。
        #expect(tracking.isDoubleLine == false)
        #expect(tracking.outlineColor == nil)
        #expect(locked.isDoubleLine == true)
        #expect(locked.outlineColor != nil)

        // 线宽关系：锁定面线粗于跟踪细线；暗描边再粗一档（视觉层级）。
        #expect(locked.strokeWidth > tracking.strokeWidth)
        #expect(locked.outlineWidth > locked.strokeWidth)

        // spec 假设锚点：跟随态约 2.5pt 细实线。
        #expect(tracking.strokeWidth == 2.5)
    }

    @Test("Resolve maps document-mode lock states to the matching style")
    func resolveMapsLockStates() {
        #expect(DocumentFrameStyle.resolve(isLocked: false, mode: .document) == .tracking)
        #expect(DocumentFrameStyle.resolve(isLocked: true, mode: .document) == .locked)
    }

    @Test("Document frame style never applies to id card mode")
    func idCardIsGuarded() {
        // FR-003：证件模式渲染路径完全不变——idCard 两态都拿不到文档整框样式
        //（idMask + 专用描边路径与文档样式解耦）。
        #expect(DocumentFrameStyle.resolve(isLocked: false, mode: .idCard) == nil)
        #expect(DocumentFrameStyle.resolve(isLocked: true, mode: .idCard) == nil)
    }
}
