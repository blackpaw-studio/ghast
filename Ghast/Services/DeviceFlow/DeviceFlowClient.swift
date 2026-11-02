import Foundation

struct DeviceCode: Sendable, Equatable {
    let deviceCode: String
    let userCode: String
    let verificationURI: URL
    let expiresIn: Int
    let interval: Int
}

enum DeviceFlowError: Error, Sendable, Equatable {
    case expired
    case denied
    case disabled
    case network(String)
    case unexpected(String)
}

typealias Sleeper = @Sendable (Duration) async throws -> Void

protocol DeviceFlowClienting: Sendable {
    func requestCode(scopes: [String]) async throws -> DeviceCode
    func pollForToken(_ code: DeviceCode) async throws -> String
}

struct DeviceFlowClient: DeviceFlowClienting {
    static let defaultClientID = "Ov23liLVIllxzZoRYwAN"

    let clientID: String
    let transport: any HTTPTransport
    let sleeper: Sleeper

    init(
        clientID: String = DeviceFlowClient.defaultClientID,
        transport: any HTTPTransport = URLSessionTransport(),
        sleeper: @escaping Sleeper = { try await Task.sleep(for: $0) }
    ) {
        self.clientID = clientID
        self.transport = transport
        self.sleeper = sleeper
    }

    func requestCode(scopes: [String]) async throws -> DeviceCode {
        let fields = ["client_id": clientID, "scope": scopes.joined(separator: " ")]
        let payload: CodeResponse = try await post(Endpoint.deviceCode, fields: fields)
        if let error = payload.error { throw Self.map(errorCode: error) }
        guard let deviceCode = payload.deviceCode,
              let userCode = payload.userCode,
              let uri = payload.verificationURI.flatMap(URL.init(string:)),
              let expiresIn = payload.expiresIn else {
            throw DeviceFlowError.unexpected("Malformed device code response")
        }
        return DeviceCode(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURI: uri,
            expiresIn: expiresIn,
            interval: payload.interval ?? Self.defaultInterval
        )
    }

    /// Polls until the user approves. Elapsed time is the sum of the waits, so the
    /// loop needs no clock. Cancellation surfaces as `CancellationError`.
    func pollForToken(_ code: DeviceCode) async throws -> String {
        var interval = code.interval
        var elapsed = 0
        let fields = [
            "client_id": clientID,
            "device_code": code.deviceCode,
            "grant_type": Self.grantType,
        ]

        while true {
            try await sleeper(.seconds(interval))
            try Task.checkCancellation()
            elapsed += interval
            if elapsed > code.expiresIn { throw DeviceFlowError.expired }

            let reply: TokenResponse = try await post(Endpoint.accessToken, fields: fields)
            if let token = reply.accessToken { return token }
            switch reply.error {
            case "authorization_pending":
                continue
            case "slow_down":
                interval = reply.interval ?? interval + Self.slowDownIncrement
            case let error?:
                throw Self.map(errorCode: error)
            case nil:
                throw DeviceFlowError.unexpected("Malformed token response")
            }
        }
    }
}

extension DeviceFlowClient {
    enum Endpoint {
        static let deviceCode = URL(string: "https://github.com/login/device/code")!
        static let accessToken = URL(string: "https://github.com/login/oauth/access_token")!
    }

    static let defaultInterval = 5
    static let slowDownIncrement = 5
    static let grantType = "urn:ietf:params:oauth:grant-type:device_code"

    struct CodeResponse: Decodable {
        let deviceCode: String?
        let userCode: String?
        let verificationURI: String?
        let expiresIn: Int?
        let interval: Int?
        let error: String?

        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code"
            case userCode = "user_code"
            case verificationURI = "verification_uri"
            case expiresIn = "expires_in"
            case interval, error
        }
    }

    struct TokenResponse: Decodable {
        let accessToken: String?
        let error: String?
        let interval: Int?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case error, interval
        }
    }

    /// Maps a terminal GitHub error code to a `DeviceFlowError`.
    static func map(errorCode: String) -> DeviceFlowError {
        switch errorCode {
        case "expired_token": .expired
        case "access_denied": .denied
        case "device_flow_disabled": .disabled
        default: .unexpected(errorCode)
        }
    }

    func post<Response: Decodable>(_ url: URL, fields: [String: String]) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formEncode(fields).utf8)

        let data: Data
        do {
            (data, _) = try await transport.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw DeviceFlowError.network(error.localizedDescription)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw DeviceFlowError.unexpected("Malformed response from GitHub")
        }
    }

    static func formEncode(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=")
        return fields.sorted { $0.key < $1.key }
            .map { key, value in
                let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(key)=\(encoded)"
            }
            .joined(separator: "&")
    }
}
