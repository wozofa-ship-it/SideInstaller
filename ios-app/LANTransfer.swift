import Foundation
import Network

/// 局域网传输：一个极简 HTTP 服务，把 App 的 Documents 目录
/// 开给同 Wi-Fi 的浏览器——列表、下载、上传、删除。只在本机
/// 点了「开启」才跑，关掉即停。
final class LANTransferServer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var port: Int = 0
    @Published var lastError: String?

    private var listener: NWListener?
    /// 正在尝试/运行的端口（失败回调靠它判断要不要试下一个，
    /// 避免回调闭包持有 listener 造成循环引用）。
    private var activeCandidate = 0
    private let queue = DispatchQueue(label: "czf.lan.transfer")

    private var root: URL { IPALibrary.documentsDir }

    var addressText: String {
        "http://\(Self.wifiIPAddress() ?? "127.0.0.1"):\(port)"
    }

    func start() {
        guard !isRunning else { return }
        lastError = nil
        tryPort(8088)
    }

    func stop() {
        activeCandidate = 0
        listener?.cancel()
        listener = nil
        isRunning = false
        port = 0
    }

    private func tryPort(_ candidate: Int) {
        guard candidate <= 8098 else {
            DispatchQueue.main.async { self.lastError = L("端口 8088-8098 都被占用了") }
            return
        }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(
                using: params, on: NWEndpoint.Port(rawValue: UInt16(candidate))!)
            activeCandidate = candidate
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, self.activeCandidate == candidate else { return }
                switch state {
                case .ready:
                    DispatchQueue.main.async {
                        self.isRunning = true
                        self.port = candidate
                    }
                case .failed:
                    self.listener = nil
                    self.tryPort(candidate + 1)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            tryPort(candidate + 1)
        }
    }

    // MARK: 连接与请求解析

    private struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]
        let body: Data
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
            [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buf = buffer
            if let data { buf.append(data) }
            if let request = Self.parse(buf) {
                self.respond(connection, request: request)
            } else if isComplete || error != nil || buf.count > (256 << 20) {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buf)
            }
        }
    }

    /// 数据齐了才返回请求；没齐返回 nil（继续收）。
    private static func parse(_ buf: Data) -> Request? {
        let headerEnd = Data("\r\n\r\n".utf8)
        guard let range = buf.range(of: headerEnd) else { return nil }
        let headText = String(decoding: buf[..<range.lowerBound], as: UTF8.self)
        let lines = headText.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].lowercased()
                let value = line[line.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }
        let bodyStart = range.upperBound
        let contentLength = Int(headers["content-length"] ?? "") ?? 0
        guard buf.count - bodyStart >= contentLength else { return nil }
        let body = buf[bodyStart..<(bodyStart + contentLength)]
        let rawPath = String(parts[1])
        let pathPart = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        var query: [String: String] = [:]
        if let q = rawPath.split(separator: "?", maxSplits: 1).last, rawPath.contains("?") {
            for pair in q.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    query[String(kv[0])] = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                }
            }
        }
        return Request(method: String(parts[0]), path: pathPart,
                       query: query, headers: headers, body: Data(body))
    }

    // MARK: 路由

    private func respond(_ connection: NWConnection, request: Request) {
        switch (request.method, request.path) {
        case ("GET", "/"):
            send(connection, status: "200 OK", contentType: "text/html; charset=utf-8",
                 body: Data(indexHTML().utf8))
        case ("GET", "/dl"):
            guard let rel = request.query["path"], let file = resolve(rel),
                  FileManager.default.fileExists(atPath: file.path) else {
                sendText(connection, status: "404 Not Found", text: "文件不存在")
                return
            }
            sendFile(connection, file: file)
        case ("GET", "/del"):
            guard let rel = request.query["path"], let file = resolve(rel) else {
                sendText(connection, status: "400 Bad Request", text: "路径不对")
                return
            }
            deleteFile(at: file)
            redirect(connection)
        case ("POST", "/upload"):
            guard let contentType = request.headers["content-type"],
                  let saved = Self.saveUpload(body: request.body, contentType: contentType, root: root)
            else {
                sendText(connection, status: "400 Bad Request", text: "上传解析失败")
                return
            }
            _ = saved
            redirect(connection)
        default:
            sendText(connection, status: "404 Not Found", text: "没有这个页面")
        }
    }

    /// 把相对路径钉回 Documents 里，逃不出去。
    private func resolve(_ rel: String) -> URL? {
        let decoded = rel.removingPercentEncoding ?? rel
        var url = root
        for component in decoded.split(separator: "/") {
            if component == ".." || component == "." { return nil }
            url.appendPathComponent(String(component))
        }
        let path = url.standardizedFileURL.path
        guard path == root.path || path.hasPrefix(root.path + "/") else { return nil }
        return url
    }

    private func deleteFile(at file: URL) {
        let relDir = file.deletingLastPathComponent().path
            .replacingOccurrences(of: root.path, with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if relDir == "Signed",
           let record = SignedIPAStore.load().first(where: { $0.fileName == file.lastPathComponent }) {
            SignedIPAStore.remove(record)
        } else {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: 响应发送

    private func send(_ connection: NWConnection, status: String, contentType: String,
                      body: Data, extraHeaders: [String] = []) {
        var head = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n"
        for header in extraHeaders {
            head += "\(header)\r\n"
        }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendText(_ connection: NWConnection, status: String, text: String) {
        send(connection, status: status, contentType: "text/plain; charset=utf-8",
             body: Data(text.utf8))
    }

    private func redirect(_ connection: NWConnection) {
        send(connection, status: "303 See Other", contentType: "text/plain",
             body: Data(), extraHeaders: ["Location: /"])
    }

    private func sendFile(_ connection: NWConnection, file: URL) {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int ?? 0
        let name = file.lastPathComponent
        let encoded = name.addingPercentEncoding(
            withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")) ?? "file"
        var head = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n"
        head += "Content-Length: \(size)\r\nConnection: close\r\n"
        head += "Content-Disposition: attachment; filename*=UTF-8''\(encoded)\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] _ in
            guard let self else {
                connection.cancel()
                return
            }
            self.streamFile(connection, file: file, offset: 0)
        })
    }

    private func streamFile(_ connection: NWConnection, file: URL, offset: Int) {
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            connection.cancel()
            return
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(offset))
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty {
                connection.cancel()
                return
            }
            connection.send(content: chunk, completion: .contentProcessed { [weak self] _ in
                self?.streamFile(connection, file: file, offset: offset + chunk.count)
            })
        } catch {
            connection.cancel()
        }
    }

    // MARK: 页面与上传解析

    private func indexHTML() -> String {
        let items = AppFileLibrary.scan()
        var rows = ""
        for item in items {
            let rel = item.relativeDir.isEmpty ? item.name : "\(item.relativeDir)/\(item.name)"
            let enc = rel.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? rel
            let size = ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file)
            rows += "<tr><td>\(Self.htmlEscape(rel))</td><td>\(size)</td>" +
                "<td><a href=\"/dl?path=\(enc)\">下载</a></td>" +
                "<td><a href=\"/del?path=\(enc)\" onclick=\"return confirm('删掉这个文件？')\">删除</a></td></tr>"
        }
        if items.isEmpty {
            rows = "<tr><td colspan=\"4\">（目录是空的）</td></tr>"
        }
        return """
        <!DOCTYPE html><html lang="zh"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>SideInstaller 局域网传输</title>
        <style>body{font-family:-apple-system,sans-serif;margin:24px;color:#222}
        table{border-collapse:collapse;width:100%}td,th{border-bottom:1px solid #ddd;padding:8px;text-align:left}
        a{color:#06c;text-decoration:none}</style></head><body>
        <h2>SideInstaller 文件传输</h2>
        <form method="post" action="/upload" enctype="multipart/form-data">
        <input type="file" name="file"> <button type="submit">上传</button></form>
        <table><tr><th>文件</th><th>大小</th><th></th><th></th></tr>\(rows)</table>
        </body></html>
        """
    }

    private static func htmlEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// 从 multipart/form-data 里取出文件存进目录，返回落点。
    private static func saveUpload(body: Data, contentType: String, root: URL) -> URL? {
        guard let boundaryRange = contentType.range(of: "boundary=") else { return nil }
        let boundary = String(contentType[boundaryRange.upperBound...])
            .trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        let marker = Data("--\(boundary)".utf8)
        guard let first = body.range(of: marker) else { return nil }
        let afterMarker = body[first.upperBound...]
        guard let headEnd = afterMarker.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let partHead = String(decoding: afterMarker[..<headEnd.lowerBound], as: UTF8.self)
        guard let nameRange = partHead.range(of: "filename=\"") else { return nil }
        let afterName = partHead[nameRange.upperBound...]
        guard let quoteEnd = afterName.firstIndex(of: "\"") else { return nil }
        let rawName = String(afterName[..<quoteEnd])
        let fileName = rawName.split(separator: "/").last.map(String.init) ?? "upload.bin"
        guard !fileName.isEmpty else { return nil }
        let contentStart = headEnd.upperBound
        let tail = Data("\r\n--\(boundary)".utf8)
        guard let endRange = body.range(of: tail, options: [], in: contentStart..<body.count)
        else { return nil }
        let content = body[contentStart..<endRange.lowerBound]
        var dest = root.appendingPathComponent(fileName)
        let stem = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var counter = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            let name = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
            dest = root.appendingPathComponent(name)
            counter += 1
        }
        do {
            try Data(content).write(to: dest, options: .atomic)
            return dest
        } catch {
            return nil
        }
    }

    // MARK: Wi-Fi 地址

    static func wifiIPAddress() -> String? {
        var address: String?
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(interfaces) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            if String(cString: ifa.ifa_name) == "en0" {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host,
                            socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                address = String(cString: host)
            }
        }
        return address
    }
}
