import Foundation

struct FirebaseProject {
    let projectId: String
    let displayName: String

    /// 下拉框显示行，id 在第一个 token（缓存与 Python 版共用此格式）。
    var display: String {
        "\(projectId)  \(displayName)".trimmingCharacters(in: .whitespaces)
    }
}

struct FirebaseApp {
    let appId: String
    let bundleId: String
    let displayName: String

    var display: String {
        "\(appId)  \(bundleId)  \(displayName)".trimmingCharacters(in: .whitespaces)
    }
}

struct FirebaseGroup {
    let alias: String
    let displayName: String

    var display: String {
        "\(alias)  \(displayName)".trimmingCharacters(in: .whitespaces)
    }
}

enum FirebaseParseError: LocalizedError {
    case noJSON
    case unexpectedShape(context: String, rawOutput: String)

    var errorDescription: String? {
        switch self {
        case .noJSON:
            return "输出中没有 JSON 内容。"
        case .unexpectedShape(let context, let raw):
            return "无法解析 \(context) 输出（JSON 结构不符合预期）。\n\n原始输出:\n" + String(raw.prefix(2000))
        }
    }
}

/// 防御式解析 firebase CLI 的 --json 输出（结构随 firebase-tools 版本变化，键名不固定）。
enum FirebaseParser {
    /// firebase CLI 在 JSON 前后可能打印提示行，截取第一个 "{" 到最后一个 "}" 之间的内容再解析。
    static func jsonObject(from output: String) throws -> [String: Any] {
        guard let start = output.firstIndex(of: "{") else {
            throw FirebaseParseError.noJSON
        }
        var text = String(output[start...])
        if let end = text.lastIndex(of: "}") {
            text = String(text[...end])
        }
        guard let data = text.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw FirebaseParseError.noJSON
        }
        return obj
    }

    /// 从多种可能的键名里取数组，兼容顶层直接是数组容器或 {"result": {...}} 嵌套形态。
    private static func array(from obj: [String: Any], keys: [String]) -> [[String: Any]]? {
        for key in keys {
            if let arr = obj[key] as? [[String: Any]], !arr.isEmpty {
                return arr
            }
        }
        if let result = obj["result"] as? [String: Any] {
            for key in keys where key != "result" {
                if let arr = result[key] as? [[String: Any]], !arr.isEmpty {
                    return arr
                }
            }
        }
        return nil
    }

    static func projects(from output: String) throws -> [FirebaseProject] {
        let obj = try jsonObject(from: output)
        guard let list = array(from: obj, keys: ["result", "projects"]) else {
            throw FirebaseParseError.unexpectedShape(context: "projects:list", rawOutput: output)
        }
        return list.compactMap { entry in
            let pid = (entry["projectId"] as? String)
                ?? (entry["project_id"] as? String)
                ?? (entry["id"] as? String)
            let name = (entry["displayName"] as? String) ?? (entry["name"] as? String) ?? ""
            if let pid, !pid.isEmpty {
                return FirebaseProject(projectId: pid, displayName: name)
            }
            return nil
        }
    }

    static func apps(from output: String) throws -> [FirebaseApp] {
        let obj = try jsonObject(from: output)
        guard let list = array(from: obj, keys: ["result", "apps"]) else {
            throw FirebaseParseError.unexpectedShape(context: "apps:list", rawOutput: output)
        }
        return list.compactMap { entry -> FirebaseApp? in
            let platform = ((entry["platform"] as? String) ?? (entry["appPlatform"] as? String) ?? "").uppercased()
            guard platform == "IOS" || platform == "APPLE_PLATFORM_IOS" else {
                return nil
            }
            let appId = (entry["appId"] as? String)
                ?? (entry["app_id"] as? String)
                ?? (entry["firebaseAppId"] as? String)
                ?? ""
            let bundle = (entry["bundleId"] as? String) ?? (entry["bundle_id"] as? String) ?? ""
            let name = (entry["displayName"] as? String) ?? (entry["name"] as? String) ?? ""
            return appId.isEmpty ? nil : FirebaseApp(appId: appId, bundleId: bundle, displayName: name)
        }
    }

    static func groups(from output: String) throws -> [FirebaseGroup] {
        let obj = try jsonObject(from: output)
        var list = (obj["result"] as? [String: Any])?["groups"] as? [[String: Any]]
        if list == nil {
            list = obj["groups"] as? [[String: Any]]
        }
        guard let list else {
            throw FirebaseParseError.unexpectedShape(context: "groups:list", rawOutput: output)
        }
        var result: [FirebaseGroup] = []
        for entry in list {
            // name 形如 "projects/X/groups/alias"，取末段作为 alias
            let rawName = entry["name"] as? String ?? ""
            let alias = rawName.split(separator: "/").last.map(String.init) ?? ""
            if alias.isEmpty { continue }
            let display = (entry["displayName"] as? String) ?? alias
            result.append(FirebaseGroup(alias: alias, displayName: display))
        }
        return result
    }
}
