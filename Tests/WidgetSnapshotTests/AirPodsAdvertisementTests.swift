import XCTest
@testable import Barttery

final class AirPodsAdvertisementTests: XCTestCase {
    private func data(_ hex: String) -> Data {
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return Data(bytes)
    }

    func testLidClosedBit() {
        // Company ID 0x004C, proximity-pairing type 0x07, length 0x19,
        // lid byte at offset 10 (0x0A = closed, counter 2).
        let closed = data("4C00071901242000A8600A0000000000000000000000000000000000")
        XCTAssertTrue(AirPodsReader.isLidClosed(closed))

        let open = data("4C00071901242000A860020000000000000000000000000000000000")
        XCTAssertFalse(AirPodsReader.isLidClosed(open))
    }

    func testRejectsOtherAppleMessagesAndShortPayloads() {
        let nearbyInfo = data("4C000E1901242000A86002")   // type 0x0E, not proximity pairing
        XCTAssertFalse(AirPodsReader.isLidClosed(nearbyInfo))
        XCTAssertFalse(AirPodsReader.isLidClosed(data("4C000719012420")))
    }
}
