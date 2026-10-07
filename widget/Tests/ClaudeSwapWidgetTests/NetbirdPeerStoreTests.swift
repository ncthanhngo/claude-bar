import XCTest
@testable import ClaudeSwapWidget

final class NetbirdPeerStoreTests: XCTestCase {
    func testParseSortsConnectedFirstAndConvertsLatency() throws {
        let json = """
        {"peers":{"total":3,"connected":2,"details":[
          {"fqdn":"m1.netbird.example.com","netbirdIp":"100.92.0.3","status":"Connecting","connectionType":"-","latency":0},
          {"fqdn":"ks1.netbird.example.com","netbirdIp":"100.92.0.2","status":"Connected","connectionType":"P2P","latency":103761959},
          {"fqdn":"dch.netbird.example.com","netbirdIp":"100.92.0.1","status":"Connected","connectionType":"Relayed","latency":0}
        ]}}
        """
        let peers = try XCTUnwrap(NetbirdPeerStore.parse(json))
        XCTAssertEqual(peers.map(\.name), ["dch", "ks1", "m1"])
        XCTAssertEqual(peers.map(\.isConnected), [true, true, false])
        XCTAssertEqual(peers[1].latencyMs, 104)
        XCTAssertNil(peers[0].latencyMs)
        XCTAssertEqual(peers[0].connectionType, "Relayed")
        XCTAssertEqual(peers[2].connectionType, "")
    }

    func testParseRejectsNonStatusOutput() {
        XCTAssertNil(NetbirdPeerStore.parse("Daemon status: NeedsLogin"))
        XCTAssertNil(NetbirdPeerStore.parse(""))
    }

    func testParseAcceptsNetworkWithNoPeers() {
        XCTAssertEqual(NetbirdPeerStore.parse(#"{"peers":{"details":null}}"#), [])
    }

    func testNetbirdCommandStartsWithAWordNotASlash() {
        let cmd = SSHTerminalLauncher.netbirdCommand(
            binary: "/usr/local/bin/netbird", user: "evseadmin", host: "dch.netbird.example.com")
        XCTAssertEqual(cmd, "command /usr/local/bin/netbird ssh evseadmin@dch.netbird.example.com")
        XCTAssertNil(SSHTerminalLauncher.netbirdCommand(
            binary: "/usr/local/bin/netbird", user: "a;b", host: "dch.netbird.example.com"))
    }

    func testTerminalValuesRejectShellMetacharacters() {
        XCTAssertTrue(SSHTerminalLauncher.isSafe("evseadmin", extra: "._-"))
        XCTAssertTrue(SSHTerminalLauncher.isSafe("dch.netbird.example.com", extra: ".-"))
        XCTAssertFalse(SSHTerminalLauncher.isSafe("root; rm -rf ~", extra: "._-"))
        XCTAssertFalse(SSHTerminalLauncher.isSafe("a\"b", extra: "._-"))
        XCTAssertFalse(SSHTerminalLauncher.isSafe("", extra: "._-"))
    }
}
