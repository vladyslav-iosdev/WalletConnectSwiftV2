
import Foundation
import Combine

protocol WCSubscribing: AnyObject {
    var onRequestSubscription: ((WCRequestSubscriptionPayload)->())? {get set}
    func setSubscription(topic: String)
    func removeSubscription(topic: String)
}

class WCSubscriber: WCSubscribing {
    private var relay: WalletConnectRelaying
    var onRequestSubscription: ((WCRequestSubscriptionPayload)->())?
    private let concurrentQueue = DispatchQueue(label: "wc subscriber queue: \(UUID().uuidString)",
                                                attributes: .concurrent)
    private var publishers = [AnyCancellable]()
    private let logger: BaseLogger
    var topics: [String] = []

    init(relay: WalletConnectRelaying,
         logger: BaseLogger) {
        self.relay = relay
        self.logger = logger
        setSubscribingForPayloads()
    }

    // MARK: - Sequence Subscribing Interface

    func setSubscription(topic: String) {
        logger.debug("Setting Subscription...")
        concurrentQueue.sync {
            topics.append(topic)
        }
        relay.subscribe(topic: topic)
    }
    
    func getTopics() -> [String] {
        concurrentQueue.sync {
            return topics
        }
    }
    
    func removeSubscription(topic: String) {
        concurrentQueue.sync {
            topics.removeAll {$0 == topic}
        }
        relay.unsubscribe(topic: topic)
    }
    
    private func setSubscribingForPayloads() {
        relay.clientSynchJsonRpcPublisher
            .filter {[weak self] in self?.getTopics().contains($0.topic) ?? false}
            .sink { [weak self] subscriptionPayload in
                self?.onRequestSubscription?(subscriptionPayload)
            }.store(in: &publishers)
    }
}
