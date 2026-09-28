import Foundation

struct HistoryEntry: Identifiable {
    let id = UUID()
    let releaseNote: String
    let uploadTime: String
}

/// ~/.firebase_uploader_cache.json 的读写。
/// 键名与 Python 版完全一致，两版共用同一份缓存（历史/上次选择互通）。
final class CacheStore {
    static let shared = CacheStore()

    static let historyLimit = 200

    let fileURL: URL
    private var data: [String: Any]
    private let ioQueue = DispatchQueue(label: "FirebaseUploader.cache.io")

    private init() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".firebase_uploader_cache.json")
        self.fileURL = url
        // 文件缺失/损坏时容错返回空字典（同 Python 版 _load_cache）
        if let raw = try? Data(contentsOf: url),
           let obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] {
            data = obj
        } else {
            data = [:]
        }
    }

    // MARK: - 基础读写

    func string(_ key: String) -> String? {
        data[key] as? String
    }

    func stringArray(_ key: String) -> [String] {
        data[key] as? [String] ?? []
    }

    func set(_ key: String, _ value: Any) {
        data[key] = value
        save()
    }

    private func save() {
        guard let out = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        let url = fileURL
        ioQueue.async {
            try? out.write(to: url, options: .atomic)
        }
    }

    // MARK: - 上传历史

    func history() -> [HistoryEntry] {
        guard let list = data["upload_history"] as? [[String: Any]] else {
            return []
        }
        return list.compactMap { item in
            let note = (item["release_note"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let time = (item["upload_time"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if note.isEmpty && time.isEmpty {
                return nil
            }
            return HistoryEntry(releaseNote: note, uploadTime: time)
        }
    }

    /// 头插一条记录并截断到上限，返回更新后的历史。
    func insertHistoryEntry(note: String, time: String) -> [HistoryEntry] {
        var list = data["upload_history"] as? [[String: Any]] ?? []
        list.insert(["release_note": note, "upload_time": time], at: 0)
        if list.count > Self.historyLimit {
            list = Array(list.prefix(Self.historyLimit))
        }
        data["upload_history"] = list
        save()
        return history()
    }
}
