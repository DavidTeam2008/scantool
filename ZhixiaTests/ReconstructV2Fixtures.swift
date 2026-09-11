import CoreGraphics
import Foundation
@testable import Zhixia

//  ⚠ 本文件由 Tools/ocr-dump/gen_fixtures.py 生成，请勿手改。
//  改法：改 docs/fixtures/images/ 下的样张 → 跑 main.swift 重新导出 json → 跑 gen_fixtures.py。
//
//  为什么需要它：
//  以前 ReconstructTests 用「拍脑袋合成的 CGRect」，全绿但真机样张照崩
//  （README §已知问题、docs/06 §12.4 都记了这笔账）。
//  R2 起，版面 / 表格 / 配图的断言一律建立在这份**真实样张 OCR**上。
//
//  坐标系：Vision 原生归一化，原点左下，与 OCRLine.boundingBox 一致。

/// 一张样张的真实 OCR 输出 + 人工标注的期望结构。
struct ReconstructSampleFixture: Sendable {
    var name: String
    var label: String
    var sourceImage: String
    var imageSize: CGSize
    var expectedScene: ReconstructScene
    var lines: [OCRLine]

    var joinedText: String { lines.map(\.text).joined(separator: "\n") }
}

enum ReconstructV2Fixtures {
    /// 营养成分表（小象超市芒果干）
    /// 原图：`docs/fixtures/images/nutrition-mango.jpg`
    /// 导出：34 行 OCR（Vision accurate，中英，与 App 内 VisionTextRecognizer 同参）
    static let nutritionMango = ReconstructSampleFixture(
        name: "nutritionMango",
        label: "营养成分表（小象超市芒果干）",
        sourceImage: "nutrition-mango.jpg",
        imageSize: CGSize(width: 869, height: 1024),
        expectedScene: .table,
        lines: [
        OCRLine(text: "2026/07/15", boundingBox: CGRect(x: 0.227586, y: 0.837891, width: 0.301149, height: 0.03125)),
        OCRLine(text: "01", boundingBox: CGRect(x: 0.572414, y: 0.84375, width: 0.057471, height: 0.025391)),
        OCRLine(text: "小象超市", boundingBox: CGRect(x: 0.604562, y: 0.751834, width: 0.108117, height: 0.023675)),
        OCRLine(text: "自有品牌", boundingBox: CGRect(x: 0.735632, y: 0.751953, width: 0.103448, height: 0.021484)),
        OCRLine(text: "芒果干", boundingBox: CGRect(x: 0.128736, y: 0.728516, width: 0.133333, height: 0.042969)),
        OCRLine(text: "酸甜有嚼劲丨细腻Q软丨鲜果原切", boundingBox: CGRect(x: 0.184804, y: 0.661335, width: 0.611834, height: 0.065105)),
        OCRLine(text: "◎产品类型：果脯类◎配料表：芒果（添加量≥70%）、白砂糖、食用葡萄糖、柠", boundingBox: CGRect(x: 0.134815, y: 0.610027, width: 0.735058, height: 0.046963)),
        OCRLine(text: "檬酸、焦亚硫酸钠、食用香精◎生产日期：见包装袋背面打印O保质期：12个月", boundingBox: CGRect(x: 0.132592, y: 0.584852, width: 0.73499, height: 0.048641)),
        OCRLine(text: "◎贮存条件：请放在阴凉处，避免阳光、高温、潮湿〇食用方法：开袋即食◎产", boundingBox: CGRect(x: 0.132687, y: 0.560922, width: 0.739351, height: 0.046555)),
        OCRLine(text: "品标准代号：GB/T 10782◎委托商：北京象鲜科技有限公司◎地址：北京市朝", boundingBox: CGRect(x: 0.132748, y: 0.537809, width: 0.738897, height: 0.042698)),
        OCRLine(text: "阳区小营北路15号院1号楼3层◎联系方式：010-101071770受委托商：南宁华", boundingBox: CGRect(x: 0.130703, y: 0.513185, width: 0.73884, height: 0.040858)),
        OCRLine(text: "侨投资区森景园食品有限公司◎地址：广西-东盟经济技术开发区安平路26号", boundingBox: CGRect(x: 0.130635, y: 0.488664, width: 0.736549, height: 0.039019)),
        OCRLine(text: "◎联系方式：86-771-6316366◎食品生产许可证编号：SC117450112001430", boundingBox: CGRect(x: 0.130736, y: 0.466054, width: 0.733968, height: 0.0342)),
        OCRLine(text: "产地：广西省南宁市", boundingBox: CGRect(x: 0.131034, y: 0.445313, width: 0.183908, height: 0.023438)),
        OCRLine(text: "营养成分表", boundingBox: CGRect(x: 0.436732, y: 0.40216, width: 0.119639, height: 0.023804)),
        OCRLine(text: "项目", boundingBox: CGRect(x: 0.147126, y: 0.378906, width: 0.045977, height: 0.019531)),
        OCRLine(text: "每 100克", boundingBox: CGRect(x: 0.452874, y: 0.378906, width: 0.101149, height: 0.019531)),
        OCRLine(text: "NRV%", boundingBox: CGRect(x: 0.772414, y: 0.382812, width: 0.066667, height: 0.017578)),
        OCRLine(text: "能量", boundingBox: CGRect(x: 0.149425, y: 0.353516, width: 0.045977, height: 0.021484)),
        OCRLine(text: "1429 千焦", boundingBox: CGRect(x: 0.448276, y: 0.353516, width: 0.101149, height: 0.019531)),
        OCRLine(text: "17%", boundingBox: CGRect(x: 0.790805, y: 0.357422, width: 0.050575, height: 0.019531)),
        OCRLine(text: "蛋白质", boundingBox: CGRect(x: 0.147126, y: 0.332031, width: 0.066667, height: 0.021484)),
        OCRLine(text: "1.5克", boundingBox: CGRect(x: 0.487356, y: 0.333984, width: 0.057471, height: 0.019531)),
        OCRLine(text: "3%", boundingBox: CGRect(x: 0.8, y: 0.335937, width: 0.03908, height: 0.017578)),
        OCRLine(text: "脂肪", boundingBox: CGRect(x: 0.147126, y: 0.310547, width: 0.048276, height: 0.021484)),
        OCRLine(text: "0.8克", boundingBox: CGRect(x: 0.487356, y: 0.314453, width: 0.05977, height: 0.019531)),
        OCRLine(text: "1%", boundingBox: CGRect(x: 0.802299, y: 0.316406, width: 0.034483, height: 0.017578)),
        OCRLine(text: "碳水化合物", boundingBox: CGRect(x: 0.149425, y: 0.291016, width: 0.108046, height: 0.021484)),
        OCRLine(text: "80.8克", boundingBox: CGRect(x: 0.473563, y: 0.292969, width: 0.08046, height: 0.019531)),
        OCRLine(text: "27%", boundingBox: CGRect(x: 0.790805, y: 0.294922, width: 0.048276, height: 0.017578)),
        OCRLine(text: "钠", boundingBox: CGRect(x: 0.149425, y: 0.267578, width: 0.022989, height: 0.023438)),
        OCRLine(text: "49毫克", boundingBox: CGRect(x: 0.473497, y: 0.273239, width: 0.080592, height: 0.019929)),
        OCRLine(text: "2%", boundingBox: CGRect(x: 0.802299, y: 0.273437, width: 0.036782, height: 0.017578)),
        OCRLine(text: "6 936832 529010", boundingBox: CGRect(x: 0.664368, y: 0.160156, width: 0.177011, height: 0.017578))
        ]
    )
    /// 练习册 Test 4 Questions 1~5
    /// 原图：`docs/fixtures/images/workbook-test4.jpg`
    /// 导出：48 行 OCR（Vision accurate，中英，与 App 内 VisionTextRecognizer 同参）
    static let workbookTest4 = ReconstructSampleFixture(
        name: "workbookTest4",
        label: "练习册 Test 4 Questions 1~5",
        sourceImage: "workbook-test4.jpg",
        imageSize: CGSize(width: 844, height: 1076),
        expectedScene: .exam,
        lines: [
        OCRLine(text: "Test 4", boundingBox: CGRect(x: 0.479998, y: 0.962433, width: 0.108106, height: 0.035821)),
        OCRLine(text: "Test 4 Questions 1~5（LP1-T4:Q1~3）", boundingBox: CGRect(x: 0.107034, y: 0.883179, width: 0.42858, height: 0.053486)),
        OCRLine(text: "Section 2. Dictation, listen to the radio and fill in the blanks.", boundingBox: CGRect(x: 0.10467, y: 0.816047, width: 0.57737, height: 0.059167)),
        OCRLine(text: "Section 1. Listen to the radio and choose the correct answers for questions 1~3.", boundingBox: CGRect(x: 0.109678, y: 0.833662, width: 0.747436, height: 0.066558)),
        OCRLine(text: "Question 1. What is Becky going to take for the Picnic？", boundingBox: CGRect(x: 0.104965, y: 0.785409, width: 0.540734, height: 0.051982)),
        OCRLine(text: "A", boundingBox: CGRect(x: 0.35545, y: 0.689591, width: 0.011848, height: 0.013011)),
        OCRLine(text: "B", boundingBox: CGRect(x: 0.504739, y: 0.684015, width: 0.016588, height: 0.013011)),
        OCRLine(text: "C", boundingBox: CGRect(x: 0.651659, y: 0.67658, width: 0.040284, height: 0.01487)),
        OCRLine(text: "Becky: Of course, and a bigP.22", boundingBox: CGRect(x: 0.096544, y: 0.628459, width: 0.368246, height: 0.031618)),
        OCRLine(text: "Boy: Hi Becky. Are you taking some,cans of/eMQeAtor the Dicnic ？", boundingBox: CGRect(x: 0.098504, y: 0.640279, width: 0.738967, height: 0.045476)),
        OCRLine(text: "Boy: I'm going to take a bottle of", boundingBox: CGRect(x: 0.093915, y: 0.604749, width: 0.338094, height: 0.031416)),
        OCRLine(text: "Becky：", boundingBox: CGRect(x: 0.094639, y: 0.5889, width: 0.071385, height: 0.021085)),
        OCRLine(text: "ones,I hope.", boundingBox: CGRect(x: 0.300948, y: 0.583643, width: 0.127962, height: 0.016729)),
        OCRLine(text: "Juce andsome _CakS.", boundingBox: CGRect(x: 0.442801, y: 0.591249, width: 0.330038, height: 0.044268)),
        OCRLine(text: "Question 2. How much is the mobile phone？", boundingBox: CGRect(x: 0.091714, y: 0.540634, width: 0.453923, height: 0.031984)),
        OCRLine(text: "£30", boundingBox: CGRect(x: 0.308057, y: 0.475836, width: 0.118483, height: 0.040892)),
        OCRLine(text: "£55", boundingBox: CGRect(x: 0.464455, y: 0.473978, width: 0.113744, height: 0.039033)),
        OCRLine(text: "£75", boundingBox: CGRect(x: 0.616114, y: 0.472119, width: 0.106635, height: 0.039033)),
        OCRLine(text: "A", boundingBox: CGRect(x: 0.341232, y: 0.434944, width: 0.018957, height: 0.01487)),
        OCRLine(text: "Girl: 5o, which Mobule__Pho Ae are you buying with your birthday.", boundingBox: CGRect(x: 0.082938, y: 0.39777, width: 0.736967, height: 0.037175)),
        OCRLine(text: "money，", boundingBox: CGRect(x: 0.815166, y: 0.401487, width: 0.130332, height: 0.026022)),
        OCRLine(text: "Joe？", boundingBox: CGRect(x: 0.078199, y: 0.377323, width: 0.054502, height: 0.016729)),
        OCRLine(text: "Joe: The Vox 55.It'", boundingBox: CGRect(x: 0.075829, y: 0.349442, width: 0.206161, height: 0.020446)),
        OCRLine(text: "75", boundingBox: CGRect(x: 0.184834, y: 0.321561, width: 0.054502, height: 0.026022)),
        OCRLine(text: "Lpvely bu hove to ak my P", boundingBox: CGRect(x: 0.298319, y: 0.340315, width: 0.40617, height: 0.05026)),
        OCRLine(text: "for30", boundingBox: CGRect(x: 0.720165, y: 0.352452, width: 0.116542, height: 0.023721)),
        OCRLine(text: "pounds.", boundingBox: CGRect(x: 0.867085, y: 0.352554, width: 0.083366, height: 0.019798)),
        OCRLine(text: "Girl: That's a lot of money. You could", boundingBox: CGRect(x: 0.078199, y: 0.297398, width: 0.376777, height: 0.022305)),
        OCRLine(text: "muNy_ alorof_", boundingBox: CGRect(x: 0.492891, y: 0.29368, width: 0.180095, height: 0.039033)),
        OCRLine(text: "CD", boundingBox: CGRect(x: 0.668246, y: 0.306691, width: 0.063981, height: 0.022305)),
        OCRLine(text: "for that！", boundingBox: CGRect(x: 0.758266, y: 0.306597, width: 0.092472, height: 0.016917)),
        OCRLine(text: "Joe: Well, mobiles are exenslve", boundingBox: CGRect(x: 0.070145, y: 0.256105, width: 0.400808, height: 0.047606)),
        OCRLine(text: "Question 3. Where will they buy the.eggs？", boundingBox: CGRect(x: 0.070651, y: 0.228325, width: 0.44879, height: 0.02887)),
        OCRLine(text: "小盟", boundingBox: CGRect(x: 0.606635, y: 0.16171, width: 0.049763, height: 0.020446)),
        OCRLine(text: "C", boundingBox: CGRect(x: 0.646919, y: 0.118959, width: 0.023697, height: 0.01487)),
        OCRLine(text: "Girl:Ineed some more", boundingBox: CGRect(x: 0.060976, y: 0.064651, width: 0.250038, height: 0.024332)),
        OCRLine(text: "for my_", boundingBox: CGRect(x: 0.440758, y: 0.078067, width: 0.078199, height: 0.018587)),
        OCRLine(text: "cQN", boundingBox: CGRect(x: 0.540284, y: 0.081784, width: 0.078199, height: 0.037175)),
        OCRLine(text: "，Mum.", boundingBox: CGRect(x: 0.634906, y: 0.081388, width: 0.07853, height: 0.021239)),
        OCRLine(text: "Mother: OK. We can drive out to the", boundingBox: CGRect(x: 0.057891, y: 0.032219, width: 0.386489, height: 0.040846)),
        OCRLine(text: "Aam", boundingBox: CGRect(x: 0.462085, y: 0.04461, width: 0.085308, height: 0.033457)),
        OCRLine(text: "and get some.", boundingBox: CGRect(x: 0.5639, y: 0.055377, width: 0.154191, height: 0.021215)),
        OCRLine(text: "Cirl-It\"l be", boundingBox: CGRect(x: 0.05684, y: 0.012871, width: 0.118547, height: 0.017009)),
        OCRLine(text: "to go to the", boundingBox: CGRect(x: 0.295445, y: 0.016282, width: 0.150951, height: 0.026921)),
        OCRLine(text: "SNO/ down the road, or even the", boundingBox: CGRect(x: 0.447258, y: 0.023723, width: 0.366096, height: 0.030619)),
        OCRLine(text: "maket", boundingBox: CGRect(x: 0.836493, y: 0.040892, width: 0.106635, height: 0.052045)),
        OCRLine(text: "NSA，Itwon't take us", boundingBox: CGRect(x: 0.582938, y: 0.003717, width: 0.263033, height: 0.024164)),
        OCRLine(text: "LDnY", boundingBox: CGRect(x: 0.869668, y: 0.003717, width: 0.097156, height: 0.033457))
        ]
    )

    // MARK: - 人工标注的期望结构（ground truth，来自原图肉眼核对）

    /// 营养表真实网格：6 行 × 3 列（1 行表头 + 5 行数据，不含「营养成分表」标题）。
    /// 这是 docs/07 §2.3「营养表 Word 必达」的判定基准。
    static let nutritionExpectedGrid: [[String]] = [
        ["项目", "每 100克", "NRV%"],
        ["能量", "1429 千焦", "17%"],
        ["蛋白质", "1.5克", "3%"],
        ["脂肪", "0.8克", "1%"],
        ["碳水化合物", "80.8克", "27%"],
        ["钠", "49毫克", "2%"]
    ]

    /// 营养表三列在版面中的真实中心 x（人工从原图量取，用于校验列聚类）。
    /// 当前 OnDeviceTableCluster 算出来是 [0.185, 0.378, 0.662] —— 被包装说明噪声带偏。
    static let nutritionColumnCenters: [CGFloat] = [0.175, 0.505, 0.815]

    /// 练习册里 A/B/C 三个选项字母（人工标注，用于校验「不被聚成假表」）。
    static let workbookOptionLetters: [String] = ["A", "B", "C"]

    /// 练习册底部署名/条码区（原图右下），用于校验配图候选不被漏掉。
    static let workbookExpectsFigures = true


    static var allSamples: [ReconstructSampleFixture] {
        [
        nutritionMango,
        workbookTest4,
        ]
    }
}
