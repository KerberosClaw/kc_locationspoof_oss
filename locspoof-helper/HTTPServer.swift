import Foundation
import Network

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]

    static func parse(from data: Data) -> HTTPRequest? {
        guard let str = String(data: data, encoding: .utf8) else { return nil }
        guard str.contains("\r\n\r\n") else { return nil }
        guard let firstLineEnd = str.range(of: "\r\n") else { return nil }
        let firstLine = String(str[..<firstLineEnd.lowerBound])
        let parts = firstLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }
        let method = parts[0]
        let urlPart = parts[1]
        let pathOnly: String
        var queryDict: [String: String] = [:]
        if let qIdx = urlPart.firstIndex(of: "?") {
            pathOnly = String(urlPart[..<qIdx])
            let qs = String(urlPart[urlPart.index(after: qIdx)...])
            for kv in qs.split(separator: "&") {
                let pair = kv.split(separator: "=", maxSplits: 1).map(String.init)
                if pair.count == 2 {
                    queryDict[pair[0]] = pair[1].removingPercentEncoding ?? pair[1]
                }
            }
        } else {
            pathOnly = urlPart
        }
        return HTTPRequest(method: method, path: pathOnly, query: queryDict)
    }
}

final class HTTPServer {
    private let helper: Helper
    private let listener: NWListener
    private let queue = DispatchQueue(label: "org.locspoof.app.helper.http")

    init(helper: Helper, port: UInt16) throws {
        self.helper = helper
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw HelperError.tunnelStartFailed("invalid port \(port)")
        }
        self.listener = try NWListener(using: params, on: nwPort)
    }

    func start() {
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        listener.stateUpdateHandler = { state in
            log("[http] listener \(state)")
        }
        listener.start(queue: queue)
        log("[http] listening on 127.0.0.1:\(listener.port?.rawValue ?? 0)")
    }

    private func handle(_ conn: NWConnection) {
        if !isLoopback(conn.endpoint) {
            log("[http] reject non-loopback: \(conn.endpoint)")
            conn.cancel()
            return
        }
        conn.start(queue: queue)
        receiveRequest(conn, accumulated: Data()) { [weak self] request in
            guard let self = self else {
                conn.cancel()
                return
            }
            let response = request.map { self.dispatch($0) } ?? self.statusOnly(400, "bad request")
            conn.send(content: response, completion: .contentProcessed { _ in
                conn.cancel()
            })
        }
    }

    private func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        if case .hostPort(host: let host, port: _) = endpoint {
            switch host {
            case .ipv4(let ip): return ip == .loopback
            case .ipv6(let ip): return ip == .loopback
            case .name(let name, _): return name == "127.0.0.1" || name == "localhost"
            @unknown default: return false
            }
        }
        return false
    }

    private func receiveRequest(
        _ conn: NWConnection,
        accumulated: Data,
        completion: @escaping (HTTPRequest?) -> Void
    ) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if let error = error {
                log("[http] receive error: \(error)")
                completion(nil)
                return
            }
            var buf = accumulated
            if let data = data { buf.append(data) }
            if let request = HTTPRequest.parse(from: buf) {
                completion(request)
            } else if isComplete || buf.count > 65535 {
                completion(nil)
            } else {
                self.receiveRequest(conn, accumulated: buf, completion: completion)
            }
        }
    }

    private func dispatch(_ req: HTTPRequest) -> Data {
        switch (req.method, req.path) {
        case ("GET", "/api/status"):
            return jsonResponse(200, helper.statusDict)
        case ("GET", "/api/loc"):
            guard let lat = req.query["lat"].flatMap(Double.init),
                  let lon = req.query["lon"].flatMap(Double.init)
            else {
                return jsonResponse(400, ["error": "missing or invalid lat/lon"])
            }
            do {
                let seq = try helper.inject(lat: lat, lon: lon)
                return jsonResponse(200, ["ok": true, "seq": seq, "lat": lat, "lon": lon])
            } catch {
                return jsonResponse(500, ["error": "\(error)"])
            }
        case ("POST", "/api/clear"):
            do {
                try helper.clear()
                return jsonResponse(200, ["ok": true])
            } catch {
                return jsonResponse(500, ["error": "\(error)"])
            }
        default:
            return jsonResponse(404, ["error": "not found"])
        }
    }

    private func jsonResponse(_ status: Int, _ body: Any) -> Data {
        let json = (try? JSONSerialization.data(withJSONObject: body, options: [])) ?? Data("{}".utf8)
        let header =
            "HTTP/1.1 \(status) \(reason(status))\r\n" +
            "Content-Type: application/json\r\n" +
            "Content-Length: \(json.count)\r\n" +
            "Connection: close\r\n\r\n"
        var resp = header.data(using: .utf8) ?? Data()
        resp.append(json)
        return resp
    }

    private func statusOnly(_ status: Int, _ message: String) -> Data {
        let body = Data(message.utf8)
        let header =
            "HTTP/1.1 \(status) \(reason(status))\r\n" +
            "Content-Type: text/plain\r\n" +
            "Content-Length: \(body.count)\r\n" +
            "Connection: close\r\n\r\n"
        var resp = header.data(using: .utf8) ?? Data()
        resp.append(body)
        return resp
    }

    private func reason(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }
}
