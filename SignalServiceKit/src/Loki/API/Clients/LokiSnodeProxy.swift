import PromiseKit

internal class LokiSnodeProxy: LokiHttpClient {
    internal let target: LokiAPITarget
    
    internal enum Error : LocalizedError {
        case invalidPublicKeys
        case failedToEncryptRequest
        case failedToParseProxyResponse
        case targetNodeHttpError(code: Int, message: Any?)
           
        public var errorDescription: String? {
           switch self {
            case .invalidPublicKeys: return "Invalid target public key"
            case .failedToEncryptRequest: return "Failed to encrypt request"
            case .failedToParseProxyResponse: return "Failed to parse proxy response"
           case .targetNodeHttpError(let code, let message): return "Target node returned error \(code) - \(message ?? "No message provided")"
           }
        }
    }
    
    // MARK: - Http
    private var sessionManager: AFHTTPSessionManager = {
        let manager = AFHTTPSessionManager(sessionConfiguration: URLSessionConfiguration.ephemeral)
        let securityPolicy = AFSecurityPolicy.default()
        securityPolicy.allowInvalidCertificates = true
        securityPolicy.validatesDomainName = false
        manager.securityPolicy = securityPolicy
        manager.responseSerializer = AFHTTPResponseSerializer()
        return manager
    }()
    
    // MARK: - Ephemeral key
    private var _kp: ECKeyPair
    private var _lastGenerated: TimeInterval
    private let keyPairRefreshTime: TimeInterval = 3 * 60 * 1000 // 3 minutes
    
    // MARK: - Class functions
    
    init(target: LokiAPITarget) {
        self.target = target
        _kp = Curve25519.generateKeyPair()
        _lastGenerated = Date().timeIntervalSince1970
        super.init()
    }
    
    private func getKeyPair() -> ECKeyPair {
        if (Date().timeIntervalSince1970 > _lastGenerated + keyPairRefreshTime) {
            _kp = Curve25519.generateKeyPair()
            _lastGenerated = Date().timeIntervalSince1970
        }
        return _kp
    }
    
    override func perform(_ request: TSRequest, withCompletionQueue queue: DispatchQueue = DispatchQueue.main) -> Promise<Any> {
        guard let targetHexEncodedPublicKeys = target.publicKeys else {
            return Promise(error: Error.invalidPublicKeys)
        }
        
        let keyPair = getKeyPair()
        guard let symmetricKey = try? Curve25519.generateSharedSecret(fromPublicKey: Data(hex: targetHexEncodedPublicKeys.encryption), privateKey: keyPair.privateKey) else {
            return Promise(error: Error.failedToEncryptRequest)
        }
                
        return LokiAPI.getRandomSnode().then { snode -> Promise<Any> in
            let url = "\(snode.address):\(snode.port)/proxy"
            print("[Loki][Snode proxy] Proxy request to \(self.target) via \(snode).")
            var peepee = request.parameters
            let jsonBodyData = try JSONSerialization.data(withJSONObject: peepee, options: [])
            let jsonBodyString = String(bytes: jsonBodyData, encoding: .utf8)
            let params: [String : Any] = [ "method" : request.httpMethod, "body" : jsonBodyString, "headers" : self.getHeaders(request: request) ]
            let jsonParams = try JSONSerialization.data(withJSONObject: params, options: [])
            let ivAndCipherText = try DiffieHellman.encrypt(jsonParams, using: symmetricKey)
            let headers = [ "X-Sender-Public-Key" : keyPair.publicKey.hexadecimalString, "X-Target-Snode-Key" : targetHexEncodedPublicKeys.identification]
            return self.post(url: url, body: ivAndCipherText, headers: headers, timeoutInterval: request.timeoutInterval)
        }.map { response in
            guard response is Data, let cipherText = Data(base64Encoded: response as! Data) else {
                print("[Loki][Snode proxy] Received non-string response")
                return response
            }
            
            let decrypted = try DiffieHellman.decrypt(cipherText, using: symmetricKey)
            
            // Unwrap and handle errors if needed
            guard let json = try? JSONSerialization.jsonObject(with: decrypted, options: .allowFragments) as? [String: Any], let code = json["status"] as? Int else {
                throw HttpError.networkError(code: -1, response: nil, underlyingError: Error.failedToParseProxyResponse)
            }
            
            let success = (200..<300).contains(code)
            var body: Any? = nil
            if let string = json["body"] as? String {
                if let jsonBody = try? JSONSerialization.jsonObject(with: string.data(using: .utf8)!, options: .allowFragments) as? [String: Any] {
                    body = jsonBody
                } else {
                    body = string
                }
            }
            
            if (!success) {
                throw HttpError.networkError(code: code, response: body, underlyingError: Error.targetNodeHttpError(code: code, message: body))
            }
            
            return body
        }.recover { error -> Promise<Any> in
            print("[Loki][Snode proxy] Failed proxy request. \(error.localizedDescription)")
            throw HttpError.from(error: error) ?? error
        }
    }
    
    private func getHeaders(request: TSRequest) -> [String: Any] {
        guard let headers = request.allHTTPHeaderFields else {
            return [:]
        }
        var newHeaders: [String: Any] = [:]
        for header in headers {
            var value: Any = header.value
            // We need to convert any string boolean values to actual boolean values
            if (header.value.lowercased() == "true" || header.value.lowercased() == "false") {
                value = NSString(string: header.value).boolValue
            }
            newHeaders[header.key] = value
        }
        return newHeaders
    }
    
    private func post(url: String, body: Data?, headers: [String: String]?, timeoutInterval: TimeInterval) -> Promise<Any> {
        let (promise, resolver) = Promise<Any>.pending()
        let request = AFHTTPRequestSerializer().request(withMethod: "POST", urlString: url, parameters: nil, error: nil)
        request.allHTTPHeaderFields = headers
        request.httpBody = body
        request.timeoutInterval = timeoutInterval
        
        var task: URLSessionDataTask? = nil
        
        task = sessionManager.dataTask(with: request as URLRequest) { (response, result, error) in
            if let error = error {
                if let task = task {
                    let nmError = NetworkManagerError.taskError(task: task, underlyingError: error)
                    let nsError: NSError = nmError as NSError
                    nsError.isRetryable = false
                    resolver.reject(nsError)
                } else {
                    resolver.reject(error)
                }
            } else {
                OutageDetection.shared.reportConnectionSuccess()
                resolver.fulfill(result)
            }
        }
        
        task?.resume()
        return promise
    }
}
