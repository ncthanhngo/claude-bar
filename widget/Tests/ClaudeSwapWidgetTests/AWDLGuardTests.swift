import XCTest
import Darwin
@testable import ClaudeSwapWidget

final class AWDLGuardTests: XCTestCase {
    private func ifinfo(type: Int32 = RTM_IFINFO, index: UInt16, flags: Int32) -> [UInt8] {
        var msg = if_msghdr()
        msg.ifm_msglen = UInt16(MemoryLayout<if_msghdr>.size)
        msg.ifm_version = UInt8(RTM_VERSION)
        msg.ifm_type = UInt8(type)
        msg.ifm_index = index
        msg.ifm_flags = flags
        return withUnsafeBytes(of: &msg) { Array($0) }
    }

    func testParsesUpAndDownForMatchingInterface() {
        let up = ifinfo(index: 7, flags: IFF_UP | IFF_BROADCAST)
        XCTAssertEqual(AWDLGuard.parseInterfaceInfo(up, length: up.count, index: 7), true)
        let down = ifinfo(index: 7, flags: IFF_BROADCAST)
        XCTAssertEqual(AWDLGuard.parseInterfaceInfo(down, length: down.count, index: 7), false)
    }

    func testIgnoresOtherInterfacesAndMessageTypes() {
        let other = ifinfo(index: 3, flags: IFF_UP)
        XCTAssertNil(AWDLGuard.parseInterfaceInfo(other, length: other.count, index: 7))
        let addr = ifinfo(type: RTM_NEWADDR, index: 7, flags: IFF_UP)
        XCTAssertNil(AWDLGuard.parseInterfaceInfo(addr, length: addr.count, index: 7))
    }

    func testIgnoresTruncatedMessages() {
        let up = ifinfo(index: 7, flags: IFF_UP)
        XCTAssertNil(AWDLGuard.parseInterfaceInfo(up, length: 8, index: 7))
    }

    func testReadIsUpMatchesIfconfig() throws {
        guard let up = AWDLGuard.readIsUp() else { throw XCTSkip("no awdl0 on this Mac") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
        p.arguments = ["awdl0"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run(); p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let flags = out.split(separator: ">").first ?? ""
        XCTAssertEqual(up, flags.contains("<UP") || flags.contains(",UP"))
    }
}
