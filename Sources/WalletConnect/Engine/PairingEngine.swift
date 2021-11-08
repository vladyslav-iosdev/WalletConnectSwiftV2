import Foundation
import Combine

final class PairingEngine {
    private let wcSubscriber: WCSubscribing
    private let relayer: WalletConnectRelaying
    private let crypto: Crypto
    private var isController: Bool
    var sequencesStore: SequenceStore<PairingSequence>
    var onSessionProposal: ((SessionType.Proposal)->())?
    var onPairingApproved: ((Pairing, String, RelayProtocolOptions)->())?
    private var metadata: AppMetadata
    private var publishers = [AnyCancellable]()
    private let logger: BaseLogger
    
    init(relay: WalletConnectRelaying,
         crypto: Crypto,
         subscriber: WCSubscribing,
         sequencesStore: SequenceStore<PairingSequence>,
         isController: Bool,
         metadata: AppMetadata,
         logger: BaseLogger) {
        self.relayer = relay
        self.crypto = crypto
        self.wcSubscriber = subscriber
        self.metadata = metadata
        self.sequencesStore = sequencesStore
        self.isController = isController
        self.logger = logger
        setUpWCRequestHandling()
        restoreSubscriptions()
    }
    
    // make a public pairing type
    func pair(_ proposal: PairingType.Proposal, completion: @escaping (Result<Pairing, Error>) -> Void) {
        let privateKey = Crypto.X25519.generatePrivateKey()
        let selfPublicKey = privateKey.publicKey.toHexString()
        
//        let pendingPairing = PairingType.Pending(
//            status: .responded,
//            topic: proposal.topic,
//            relay: proposal.relay,
//            self: PairingType.Participant(publicKey: selfPublicKey),
//            proposal: proposal)
//
//        wcSubscriber.setSubscription(topic: proposal.topic)
//        sequencesStore.create(topic: proposal.topic, sequenceState: .pending(pendingPairing))
        
        let pending = PairingSequence.Pending(
            proposal: proposal,
            status: .responded)
        var pairingSequence = PairingSequence(
            topic: proposal.topic,
            relay: proposal.relay,
            self: PairingType.Participant(publicKey: selfPublicKey, metadata: metadata),
            expiryDate: Date(timeIntervalSinceNow: TimeInterval(Time.day)),
            sequenceState: .left(pending))
        
        wcSubscriber.setSubscription(topic: proposal.topic)
        try? sequencesStore.set(pairingSequence, forKey: proposal.topic)
        
        // settle on topic B
        let agreementKeys = try! Crypto.X25519.generateAgreementKeys(
            peerPublicKey: Data(hex: proposal.proposer.publicKey),
            privateKey: privateKey)
        let settledTopic = agreementKeys.sharedSecret.sha256().toHexString()
        let selfParticipant = PairingType.Participant(publicKey: selfPublicKey, metadata: metadata)
        let controllerKey = proposal.proposer.controller ? proposal.proposer.publicKey : selfPublicKey
//        let settledPairing = PairingType.Settled(
//            topic: settledTopic,
//            relay: proposal.relay,
//            self: selfParticipant,
//            peer: PairingType.Participant(publicKey: proposal.proposer.publicKey),
//            permissions: PairingType.Permissions(
//                jsonrpc: proposal.permissions.jsonrpc,
//                controller: Controller(publicKey: controllerKey)),
//            expiry: Int(Date().timeIntervalSince1970) + proposal.ttl,
//            state: nil) // FIXME: State
//
//        wcSubscriber.setSubscription(topic: settledTopic)
//        sequencesStore.update(topic: proposal.topic, newTopic: settledTopic, sequenceState: .settled(settledPairing))
        
        let settled = PairingSequence.Settled(
            peer: PairingType.Participant(publicKey: proposal.proposer.publicKey),
            permissions: PairingType.Permissions(
                jsonrpc: proposal.permissions.jsonrpc,
                controller: Controller(publicKey: controllerKey)),
            state: nil) // FIXME: State
        let settledPairing = PairingSequence(
            topic: settledTopic,
            relay: proposal.relay,
            self: selfParticipant,
            expiryDate: Date(timeIntervalSinceNow: TimeInterval(proposal.ttl)),
            sequenceState: .right(settled))
        
        wcSubscriber.setSubscription(topic: settledTopic)
        try? sequencesStore.update(topic: proposal.topic, newTopic: settledTopic, sequenceState: settledPairing)
        
        crypto.set(agreementKeys: agreementKeys, topic: settledTopic)
        crypto.set(privateKey: privateKey)
        
        // publish approve on topic A
        let approveParams = PairingType.ApproveParams(
            relay: proposal.relay,
            responder: selfParticipant,
            expiry: Int(Date().timeIntervalSince1970) + proposal.ttl,
            state: nil) // FIXME: State
        let approvalPayload = ClientSynchJSONRPC(method: .pairingApprove, params: .pairingApprove(approveParams))
        
        relayer.request(topic: proposal.topic, payload: approvalPayload) { [weak self] result in
            switch result {
            case .success:
                self?.wcSubscriber.removeSubscription(topic: proposal.topic)
                self?.logger.debug("Success on wc_pairingApprove - settled topic - \(settledTopic)")
                let pairingSuccess = Pairing(topic: settledTopic, peer: settled.peer.metadata)
                completion(.success(pairingSuccess))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
    
    func propose(_ params: ConnectParams) -> PairingType.Pending? {
        logger.debug("Propose Pairing")
        guard let topic = generateTopic() else {
            logger.debug("Could not generate topic")
            return nil
        }
        let privateKey = Crypto.X25519.generatePrivateKey()
        let publicKey = privateKey.publicKey.toHexString()
        let relay = RelayProtocolOptions(protocol: "waku", params: nil)
        crypto.set(privateKey: privateKey)
        let proposer = PairingType.Proposer(publicKey: publicKey, controller: isController)
        let uri = WalletConnectURI(topic: topic, publicKey: publicKey, isController: isController, relay: relay).absoluteString
        let signalParams = PairingType.Signal.Params(uri: uri)
        let signal = PairingType.Signal(params: signalParams)
        let permissions = getDefaultPermissions()
        let proposal = PairingType.Proposal(topic: topic, relay: relay, proposer: proposer, signal: signal, permissions: permissions, ttl: getDefaultTTL())
        let `self` = PairingType.Participant(publicKey: publicKey, metadata: metadata)
        let pending = PairingType.Pending(status: .proposed, topic: topic, relay: relay, self: `self`, proposal: proposal)
//        sequencesStore.create(topic: topic, sequenceState: .pending(pending))
        
        let pendingPairing = PairingSequence(
            topic: topic,
            relay: relay,
            self: `self`,
            expiryDate: Date(timeIntervalSinceNow: TimeInterval(Time.day)),
            sequenceState: .left(PairingSequence.Pending(proposal: proposal, status: .proposed)))
        try? sequencesStore.set(pendingPairing, forKey: topic)
        
        wcSubscriber.setSubscription(topic: topic)
        return pending
    }
    
    func ping(topic: String, completion: @escaping ((Result<Void, Error>) -> ())) {
        guard let _ = try? sequencesStore.get(key: topic) else {
            logger.debug("Could not find pairing to ping for topic \(topic)")
            return
        }
        let request = ClientSynchJSONRPC(method: .pairingPing, params: .pairingPing(PairingType.PingParams()))
        relayer.request(topic: topic, payload: request) { [unowned self] result in
            switch result {
            case .success(_):
                logger.debug("Did receive ping response")
                completion(.success(()))
            case .failure(let error):
                logger.debug("error: \(error)")
            }
        }
    }

    //MARK: - Private
    
    private func getDefaultTTL() -> Int {
        30 * Time.day
    }
    
    private func generateTopic() -> String? {
        var keyData = Data(count: 32)
        let result = keyData.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        if result == errSecSuccess {
            return keyData.toHexString()
        } else {
            print("Problem generating random bytes")
            return nil
        }
    }
    
    private func getDefaultPermissions() -> PairingType.ProposedPermissions {
        PairingType.ProposedPermissions(jsonrpc: PairingType.JSONRPC(methods: [PairingType.PayloadMethods.sessionPropose.rawValue]))
    }
    
    private func setUpWCRequestHandling() {
        wcSubscriber.onRequestSubscription = { [unowned self] subscriptionPayload in
            let requestId = subscriptionPayload.clientSynchJsonRpc.id
            let topic = subscriptionPayload.topic
            switch subscriptionPayload.clientSynchJsonRpc.params {
            case .pairingApprove(let approveParams):
                handlePairingApprove(approveParams: approveParams, pendingTopic: topic, reqestId: requestId)
            case .pairingReject(_):
                fatalError("Not Implemented")
            case .pairingUpdate(_):
                fatalError("Not Implemented")
            case .pairingUpgrade(_):
                fatalError("Not Implemented")
            case .pairingDelete(let deleteParams):
                handlePairingDelete(deleteParams, topic: topic, requestId: requestId)
            case .pairingPayload(let pairingPayload):
                self.handlePairingPayload(pairingPayload, for: topic, requestId: requestId)
            case .pairingPing(_):
                self.handlePairingPing(topic: topic, requestId: requestId)
            default:
                fatalError("not expected method type")
            }
        }
    }
    
    private func handlePairingPing(topic: String, requestId: Int64) {
        let response = JSONRPCResponse<Bool>(id: requestId, result: true)
        relayer.respond(topic: topic, payload: response) { error in
            //todo
        }
    }

    private func handlePairingPayload(_ payload: PairingType.PayloadParams, for topic: String, requestId: Int64) {
        logger.debug("Will handle pairing payload")
        guard let _ = try? sequencesStore.get(key: topic) else {
            logger.error("Pairing for the topic: \(topic) does not exist")
            return
        }
        guard payload.request.method == PairingType.PayloadMethods.sessionPropose else {
            logger.error("Forbidden WCPairingPayload method")
            return
        }
        let sessionProposal = payload.request.params
        if let pairingAgreementKeys = crypto.getAgreementKeys(for: sessionProposal.signal.params.topic) {
            crypto.set(agreementKeys: pairingAgreementKeys, topic: sessionProposal.topic)
        }
        let response = JSONRPCResponse<Bool>(id: requestId, result: true)
        relayer.respond(topic: topic, payload: response) { [weak self] error in
            self?.onSessionProposal?(sessionProposal)
        }
    }
    
    private func handlePairingDelete(_ deleteParams: PairingType.DeleteParams, topic: String, requestId: Int64) {
        logger.debug("-------------------------------------")
        logger.debug("Paired client removed pairing - reason: \(deleteParams.reason.message), code: \(deleteParams.reason.code)")
        logger.debug("-------------------------------------")
        sequencesStore.delete(forKey: topic)
        wcSubscriber.removeSubscription(topic: topic)
        let response = JSONRPCResponse<Bool>(id: requestId, result: true)
//        relayer.respond(topic: topic, payload: response) { error in
//            //todo
//        }
    }
    
    private func handlePairingApprove(approveParams: PairingType.ApproveParams, pendingTopic: String, reqestId: Int64) {
        logger.debug("Responder Client approved pairing on topic: \(pendingTopic)")
//        guard case let .pending(pairingPending) = sequencesStore.get(topic: pendingTopic) else {
//                  logger.debug("Could not find pending pairing associated with topic \(pendingTopic)")
//                  return
//        }
        guard let pairing = try? sequencesStore.get(key: pendingTopic), case let .left(pairingPending) = pairing.sequenceState else {
                  return
        }
        
//        let selfPublicKey = Data(hex: pairingPending.`self`.publicKey)
        let selfPublicKey = Data(hex: pairing.`self`.publicKey)
        let privateKey = try! crypto.getPrivateKey(for: selfPublicKey)!
        let peerPublicKey = Data(hex: approveParams.responder.publicKey)
        let agreementKeys = try! Crypto.X25519.generateAgreementKeys(peerPublicKey: peerPublicKey, privateKey: privateKey)
        let settledTopic = agreementKeys.sharedSecret.sha256().toHexString()
        crypto.set(agreementKeys: agreementKeys, topic: settledTopic)
        let proposal = pairingPending.proposal
        let controllerKey = proposal.proposer.controller ? selfPublicKey.toHexString() : proposal.proposer.publicKey
        let controller = Controller(publicKey: controllerKey)
   
//        let settledPairing = PairingType.Settled(
//            topic: settledTopic,
//            relay: approveParams.relay,
//            self: PairingType.Participant(publicKey: selfPublicKey.toHexString()),
//            peer: PairingType.Participant(publicKey: approveParams.responder.publicKey, metadata: approveParams.responder.metadata),
//            permissions: PairingType.Permissions(
//                jsonrpc: proposal.permissions.jsonrpc,
//                controller: controller),
//            expiry: approveParams.expiry,
//            state: approveParams.state)
//
//        sequencesStore.update(topic: proposal.topic, newTopic: settledTopic, sequenceState: .settled(settledPairing))
        
        let peer = PairingType.Participant(publicKey: approveParams.responder.publicKey, metadata: approveParams.responder.metadata)
        let settledPairing = PairingSequence(
            topic: settledTopic,
            relay: approveParams.relay,
            self: PairingType.Participant(publicKey: selfPublicKey.toHexString()),
            expiryDate: Date(timeIntervalSinceNow: TimeInterval(approveParams.expiry)),
            sequenceState: .right(PairingSequence.Settled(
                peer: peer,
                permissions: PairingType.Permissions(
                    jsonrpc: proposal.permissions.jsonrpc,
                    controller: controller),
                state: approveParams.state)))
        try? sequencesStore.update(topic: proposal.topic, newTopic: settledTopic, sequenceState: settledPairing)
        
        wcSubscriber.setSubscription(topic: settledTopic)
        wcSubscriber.removeSubscription(topic: proposal.topic)
        let response = JSONRPCResponse<Bool>(id: reqestId, result: true)
        relayer.respond(topic: proposal.topic, payload: response) { [weak self] error in
            let pairing = Pairing(topic: settledPairing.topic, peer: peer.metadata)
            self?.onPairingApproved?(pairing, pendingTopic, settledPairing.relay)
        }
    }
    
    private func restoreSubscriptions() {
        relayer.transportConnectionPublisher
            .sink { [unowned self] (_) in
                let topics = sequencesStore.getAll().map{$0.topic}
                topics.forEach{self.wcSubscriber.setSubscription(topic: $0)}
            }.store(in: &publishers)
    }
}
