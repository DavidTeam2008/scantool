import CoreGraphics
import Foundation
import Testing

@testable import Zhixia

/// T023（spec/scan-fidelity US5 / FR-007 / FR-011）：照片空间→屏幕解析链
/// （`OverlaySpaceMap`）全组合测试。
///
/// 断言锚定的**复合语义**：照片先落进视频视野（`FOVLayout` 中心裁切逆换算，
/// 可能出界），再随视频帧 aspectFill 进屏幕（超出 viewSize 被裁）——这**不是**
/// 「照片直接 aspectFill 进屏幕」（两者只在视频放置高度主导时数值等价）。
/// 全链 y-down 不翻转（FR-011）：两步都只做 x/y 的仿射缩放平移。
struct OverlaySpaceMapTests {
    /// 三个竖屏宽高比档位：16:9（视频典型）/ 4:3（照片典型）/ 恒等。
    private static let aspects: [Double] = [0.5625, 0.75, 1]
    /// 两种 viewSize 放置机制：390×844（0.5625 视频纵向满屏、横向裁切）、
    /// 500×500（0.5625 视频横向满屏、纵向裁切）。
    private static let viewSizes: [CGSize] = [
        CGSize(width: 390, height: 844),
        CGSize(width: 500, height: 500)
    ]

    private static func geometry(video: Double, photo: Double) -> CaptureGeometry {
        CaptureGeometry(videoAspect: video, photoAspect: photo)
    }

    /// 期望屏幕点：与实现同序的手工两步合成（照片→视频 `FOVLayout` ⊕
    /// 视频→屏幕放置线性映射）——锚「接线」，几何规则本身由
    /// `FOVLayoutTests` 与下方手算数值用例分别钉死。
    private static func expectedScreen(
        _ point: CGPoint,
        geometry: CaptureGeometry,
        viewSize: CGSize
    ) -> CGPoint {
        let videoPoint = FOVLayout.convert(
            quad: Quad(
                topLeft: point,
                topRight: point,
                bottomRight: point,
                bottomLeft: point
            ),
            fromAspect: geometry.photoAspect,
            toAspect: geometry.videoAspect
        ).topLeft
        let placement = OverlaySpaceMap.videoFramePlacement(geometry: geometry, viewSize: viewSize)
        return CGPoint(
            x: placement.minX + videoPoint.x * placement.width,
            y: placement.minY + videoPoint.y * placement.height
        )
    }

    @Test("全组合：screenQuad 与手工两步合成逐点一致（复合语义锚）")
    func screenQuadMatchesManualComposition() {
        // 带倾斜的四边形：任何坐标轴交换/翻转都会破坏逐点一致。
        let probe = Quad(
            topLeft: CGPoint(x: 0.05, y: 0.1),
            topRight: CGPoint(x: 0.95, y: 0.02),
            bottomRight: CGPoint(x: 0.9, y: 0.97),
            bottomLeft: CGPoint(x: 0.1, y: 0.88)
        )
        for video in Self.aspects {
            for photo in Self.aspects {
                for viewSize in Self.viewSizes {
                    let geometry = Self.geometry(video: video, photo: photo)
                    let screen = OverlaySpaceMap.screenQuad(
                        fromPhotoQuad: probe,
                        geometry: geometry,
                        viewSize: viewSize
                    )
                    let pairs: [(actual: CGPoint, source: CGPoint)] = [
                        (screen.topLeft, probe.topLeft),
                        (screen.topRight, probe.topRight),
                        (screen.bottomRight, probe.bottomRight),
                        (screen.bottomLeft, probe.bottomLeft)
                    ]
                    for pair in pairs {
                        let expected = Self.expectedScreen(pair.source, geometry: geometry, viewSize: viewSize)
                        #expect(
                            abs(pair.actual.x - expected.x) < 1e-9 && abs(pair.actual.y - expected.y) < 1e-9,
                            "video=\(video) photo=\(photo) view=\(viewSize)：点 \(pair.source) 应映射 \(expected)，实际 \(pair.actual)"
                        )
                    }
                }
            }
        }
    }

    @Test("恒等几何：视频==照片宽高比时 fullImage 恰为视频帧放置矩形")
    func identityAspectMapsFullImageToPlacement() {
        for aspect in Self.aspects {
            for viewSize in Self.viewSizes {
                let geometry = Self.geometry(video: aspect, photo: aspect)
                let placement = OverlaySpaceMap.videoFramePlacement(geometry: geometry, viewSize: viewSize)
                let screen = OverlaySpaceMap.screenQuad(
                    fromPhotoQuad: .fullImage,
                    geometry: geometry,
                    viewSize: viewSize
                )
                #expect(abs(screen.topLeft.x - placement.minX) < 1e-9)
                #expect(abs(screen.topLeft.y - placement.minY) < 1e-9)
                #expect(abs(screen.bottomRight.x - placement.maxX) < 1e-9)
                #expect(abs(screen.bottomRight.y - placement.maxY) < 1e-9)
            }
        }
    }

    @Test("照片比视频宽：满幅照片出界被裁，中心子区间恰铺满视频放置")
    func photoWiderThanVideoCropsToCenterSubinterval() {
        // 4:3 照片 vs 16:9 视频：照片 x∈[0,1] → 视频 x∈[−1/6, 7/6]（出界）；
        // 照片中心跨度 [0.125, 0.875] → 视频 [0,1] 恰满幅。
        let geometry = Self.geometry(video: 0.5625, photo: 0.75)
        let viewSize = CGSize(width: 390, height: 844)
        let placement = OverlaySpaceMap.videoFramePlacement(geometry: geometry, viewSize: viewSize)

        let full = OverlaySpaceMap.screenQuad(fromPhotoQuad: .fullImage, geometry: geometry, viewSize: viewSize)
        // 满幅照片左右两端都越出屏幕（横向裁切），但纵向仍贴满。
        #expect(full.topLeft.x < 0)
        #expect(full.topRight.x > viewSize.width)
        #expect(abs(full.topLeft.y - 0) < 1e-9)
        #expect(abs(full.bottomLeft.y - viewSize.height) < 1e-9)

        let centerSpan = Quad(
            topLeft: CGPoint(x: 0.125, y: 0),
            topRight: CGPoint(x: 0.875, y: 0),
            bottomRight: CGPoint(x: 0.875, y: 1),
            bottomLeft: CGPoint(x: 0.125, y: 1)
        )
        let span = OverlaySpaceMap.screenQuad(fromPhotoQuad: centerSpan, geometry: geometry, viewSize: viewSize)
        #expect(abs(span.topLeft.x - placement.minX) < 1e-9)
        #expect(abs(span.topRight.x - placement.maxX) < 1e-9)
    }

    @Test("照片比视频窄：照片满幅落入视频中心子区间（不出界）")
    func photoNarrowerThanVideoStaysInside() {
        // 16:9 照片 vs 4:3 视频：照片 x∈[0,1] → 视频 [0.125, 0.875]。
        let geometry = Self.geometry(video: 0.75, photo: 0.5625)
        let viewSize = CGSize(width: 390, height: 844)
        let placement = OverlaySpaceMap.videoFramePlacement(geometry: geometry, viewSize: viewSize)

        let screen = OverlaySpaceMap.screenQuad(fromPhotoQuad: .fullImage, geometry: geometry, viewSize: viewSize)
        // 照片视野比视频宽：照片满幅收进视频可见区（屏幕上落在放置矩形内）。
        #expect(abs(screen.topLeft.x - (placement.minX + 0.125 * placement.width)) < 1e-9)
        #expect(abs(screen.topRight.x - (placement.minX + 0.875 * placement.width)) < 1e-9)
        #expect(screen.topLeft.x >= placement.minX)
        #expect(screen.topRight.x <= placement.maxX)
    }

    @Test("y-down 全链不翻转：y 只做平移缩放，顶在屏幕上、底在屏幕下（FR-011）")
    func yAxisStaysDownAcrossAllCombinations() {
        let probe = Quad(
            topLeft: CGPoint(x: 0.2, y: 0.1),
            topRight: CGPoint(x: 0.8, y: 0.1),
            bottomRight: CGPoint(x: 0.8, y: 0.9),
            bottomLeft: CGPoint(x: 0.2, y: 0.9)
        )
        for video in Self.aspects {
            for photo in Self.aspects {
                for viewSize in Self.viewSizes {
                    let geometry = Self.geometry(video: video, photo: photo)
                    let placement = OverlaySpaceMap.videoFramePlacement(geometry: geometry, viewSize: viewSize)
                    let screen = OverlaySpaceMap.screenQuad(
                        fromPhotoQuad: probe,
                        geometry: geometry,
                        viewSize: viewSize
                    )
                    // 任何一步翻转 y 都会破坏这两条等式（y↦minY+(1−y)×height）。
                    #expect(abs(screen.topLeft.y - (placement.minY + 0.1 * placement.height)) < 1e-9)
                    #expect(abs(screen.bottomLeft.y - (placement.minY + 0.9 * placement.height)) < 1e-9)
                    #expect(
                        screen.topLeft.y < screen.bottomLeft.y,
                        "video=\(video) photo=\(photo) view=\(viewSize)：y 轴被翻转"
                    )
                }
            }
        }
    }

    @Test("视频帧放置：横向裁切+纵向满屏 / 横向满屏+纵向裁切两种机制")
    func placementCropsOnlyOneAxis() {
        // 390×844 + 16:9 视频：纵向恰满屏（minY=0），横向超宽被裁（minX<0）。
        let tall = OverlaySpaceMap.videoFramePlacement(
            geometry: Self.geometry(video: 0.5625, photo: 0.75),
            viewSize: CGSize(width: 390, height: 844)
        )
        #expect(abs(tall.minY - 0) < 1e-9)
        #expect(abs(tall.height - 844) < 1e-9)
        #expect(abs(tall.width - 474.75) < 1e-9)
        #expect(abs(tall.minX + 42.375) < 1e-9)

        // 500×500 + 16:9 视频：横向恰满屏（minX=0），纵向超高被裁（minY<0）。
        let square = OverlaySpaceMap.videoFramePlacement(
            geometry: Self.geometry(video: 0.5625, photo: 0.75),
            viewSize: CGSize(width: 500, height: 500)
        )
        #expect(abs(square.minX - 0) < 1e-9)
        #expect(abs(square.width - 500) < 1e-9)
        #expect(square.height > 500)
        #expect(square.minY < 0)
    }

    @Test("退化输入：screenQuad 非法几何/零视图原样返回；放置只依赖视频 aspect")
    func degenerateInputsAreInert() {
        let probe = Quad(
            topLeft: CGPoint(x: 0.1, y: 0.1),
            topRight: CGPoint(x: 0.9, y: 0.1),
            bottomRight: CGPoint(x: 0.9, y: 0.9),
            bottomLeft: CGPoint(x: 0.1, y: 0.9)
        )
        let viewSize = CGSize(width: 390, height: 844)

        // screenQuad 消费全部入参：任一退化（video/photo aspect 非法、viewSize 为零）
        // → 原样返回（与 FOVLayout 容错契约一致：不崩溃、不变形）。
        let degenerate: [CaptureGeometry] = [
            CaptureGeometry(videoAspect: 0, photoAspect: 0.75),
            CaptureGeometry(videoAspect: 0.5625, photoAspect: -1),
            CaptureGeometry(videoAspect: .nan, photoAspect: 0.75),
            CaptureGeometry(videoAspect: 0.5625, photoAspect: .infinity)
        ]
        for geometry in degenerate {
            #expect(
                OverlaySpaceMap.screenQuad(fromPhotoQuad: probe, geometry: geometry, viewSize: viewSize) == probe,
                "video=\(geometry.videoAspect) photo=\(geometry.photoAspect) 应原样返回"
            )
        }
        #expect(
            OverlaySpaceMap.screenQuad(
                fromPhotoQuad: probe,
                geometry: Self.geometry(video: 0.5625, photo: 0.75),
                viewSize: .zero
            ) == probe
        )

        // videoFramePlacement 只消费视频 aspect + viewSize（照片 aspect 不参与放置）：
        // 视频侧退化 / 零视图 → 归零。
        #expect(OverlaySpaceMap.videoFramePlacement(geometry: CaptureGeometry(videoAspect: 0, photoAspect: 0.75), viewSize: viewSize) == .zero)
        #expect(OverlaySpaceMap.videoFramePlacement(geometry: CaptureGeometry(videoAspect: .nan, photoAspect: 0.75), viewSize: viewSize) == .zero)
        #expect(OverlaySpaceMap.videoFramePlacement(geometry: Self.geometry(video: 0.5625, photo: 0.75), viewSize: .zero) == .zero)

        // 照片侧退化不影响放置：与同视频 aspect 的正常几何放置一致。
        let photoDegenerate = CaptureGeometry(videoAspect: 0.5625, photoAspect: -1)
        #expect(
            OverlaySpaceMap.videoFramePlacement(geometry: photoDegenerate, viewSize: viewSize)
                == OverlaySpaceMap.videoFramePlacement(geometry: Self.geometry(video: 0.5625, photo: 0.75), viewSize: viewSize),
            "照片 aspect 非法不应影响视频帧放置"
        )
    }
}
