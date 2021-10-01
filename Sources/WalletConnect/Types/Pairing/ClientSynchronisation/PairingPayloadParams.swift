
import Foundation

extension PairingType {
    struct PayloadParams: Codable, Equatable {
        let request: Request
    }
    
}
extension PairingType.PayloadParams {
    struct Request: Codable, Equatable {
        let method: PairingType.PayloadMethods
        let params: SessionType.ProposeParams
        
        enum CodingKeys: CodingKey {
            case method
            case params
        }
        
        init(method: PairingType.PayloadMethods, params: SessionType.ProposeParams) {
            self.method = method
            self.params = params
        }
        
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            method  = try container.decode(PairingType.PayloadMethods.self, forKey: .method)
            let paramsString  = try container.decode(String.self, forKey: .params)
            let paramsData = paramsString.data(using: .utf8)!
            params = try JSONDecoder().decode(SessionType.ProposeParams.self, from: paramsData)
        }
        
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(method, forKey: .method)
            let jsonString = try params.json()
            try container.encode(jsonString, forKey: .params)
        }
    }
}
