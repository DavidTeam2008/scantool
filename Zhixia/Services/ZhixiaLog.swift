import os

enum ZhixiaLog {
    static let capture = Logger(subsystem: "com.david.Zhixia", category: "capture")
    static let store = Logger(subsystem: "com.david.Zhixia", category: "store")
    static let image = Logger(subsystem: "com.david.Zhixia", category: "image")
}
