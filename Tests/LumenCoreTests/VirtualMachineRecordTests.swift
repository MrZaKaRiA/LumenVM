import XCTest
@testable import LumenCore

final class VirtualMachineRecordTests: XCTestCase {
    func testOlderRecordsDecodeWithAppleVirtualizationFeaturesOff() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Old Ubuntu","guest":"ubuntu","cpuCount":4,"memoryGiB":8,"diskGiB":64}"#
        let record = try JSONDecoder().decode(VirtualMachineRecord.self, from: Data(json.utf8))
        XCTAssertFalse(record.linuxRosetta)
        XCTAssertFalse(record.nestedVirtualization)
    }

    func testNewRecordsDefaultFeaturesOffAndRoundTripWhenEnabled() throws {
        var record = VirtualMachineRecord(name: "Dev box", guest: .debian)
        XCTAssertFalse(record.linuxRosetta)
        XCTAssertFalse(record.nestedVirtualization)
        record.linuxRosetta = true
        record.nestedVirtualization = true
        let restored = try JSONDecoder().decode(VirtualMachineRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(restored, record)
        XCTAssertTrue(restored.linuxRosetta)
        XCTAssertTrue(restored.nestedVirtualization)
    }
}
