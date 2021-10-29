
import Foundation
import XCTest
@testable import WalletConnect

class SessionEngineTests: XCTestCase {
    var engine: SessionEngine!
    var relay: MockedWCRelay!
    var crypto: Crypto!
    var subscriber: MockedSubscriber!
    
    override func setUp() {
        crypto = Crypto(keychain: DictionaryKeychain())
        relay = MockedWCRelay()
        subscriber = MockedSubscriber()
        let meta = AppMetadata(name: "", description: "", url: "", icons: [])
        let logger = MuteLogger()
        engine = SessionEngine(relay: relay, crypto: crypto, subscriber: subscriber, sequencesStore: SessionDictionaryStore(logger: logger), isController: false, metadata: meta, logger: logger)
    }

    override func tearDown() {
        relay = nil
        engine = nil
        crypto = nil
    }
}

