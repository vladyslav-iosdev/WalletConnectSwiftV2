import Foundation

protocol Expirable {
    var expiryDate: Date { get }
}

struct PairingSequence: Codable, Expirable {
    let topic: String
    let relay: RelayProtocolOptions
    let `self`: PairingType.Participant
    let expiryDate: Date
    let sequenceState: Either<Pending, Settled>
    
    
    struct Pending: Codable {
        let proposal: PairingType.Proposal
        let status: PairingType.Pending.PendingStatus
    }
    
    struct Settled: Codable {
        let peer: PairingType.Participant
        let permissions: PairingType.Permissions
        let state: PairingType.State?
    }
}

final class SequenceStore {
    
    private let defaults = UserDefaults.standard
    private let dateInitializer: () -> Date
    
    init(dateInitializer: @escaping () -> Date = Date.init) {
        self.dateInitializer = dateInitializer
    }
    
    func set<T>(_ item: T, forKey key: String) throws where T: Codable {
        let encoded = try JSONEncoder().encode(item)
        defaults.set(encoded, forKey: key)
    }
    
    func get<T>(key: String) throws -> T? where T: Codable, T: Expirable {
        guard let data = defaults.object(forKey: key) as? Data else { return nil }
        let item = try JSONDecoder().decode(T.self, from: data)
        
        let now = dateInitializer()
        if now >= item.expiryDate {
            defaults.removeObject(forKey: key)
            // call expire event
            return nil
        }
        return item
    }
    
    func getAll<T>() -> [T] where T: Codable, T: Expirable {
        return defaults.dictionaryRepresentation().compactMap {
            if let data = $0.value as? Data, let item = try? JSONDecoder().decode(T.self, from: data) {
                
                let now = dateInitializer()
                if now >= item.expiryDate {
                    defaults.removeObject(forKey: $0.key)
                    // call expire event
                    return nil
                }
                return item
            }
            return nil
        }
    }
    
    // change signature
    func update<T>(topic: String, newTopic: String? = nil, sequenceState: T) throws where T: Codable {
        if let newTopic = newTopic {
            defaults.removeObject(forKey: topic)
//            create(topic: newTopic, sequenceState: sequenceState)
            try set(sequenceState, forKey: newTopic)
        } else {
//            create(topic: topic, sequenceState: sequenceState)
            try set(sequenceState, forKey: topic)
        }
    }
    
    func delete(forKey key: String) {
        defaults.removeObject(forKey: key)
    }
}
