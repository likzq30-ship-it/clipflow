import XCTest
@testable import ClipFlow

@MainActor
final class LaunchAtLoginServiceTests: XCTestCase {
    func testRegistrationSuccessUpdatesState() {
        let registrar = FakeLoginItemRegistrar(isRegistered: false)
        let service = LaunchAtLoginService(registrar: registrar)

        XCTAssertTrue(service.setEnabled(true))

        XCTAssertTrue(service.isEnabled)
        XCTAssertTrue(registrar.isRegistered)
        XCTAssertNil(service.lastError)
        XCTAssertEqual(registrar.registerCount, 1)
    }

    func testRegistrationFailureRollsBackState() {
        let registrar = FakeLoginItemRegistrar(isRegistered: false)
        registrar.failRegister = true
        let service = LaunchAtLoginService(registrar: registrar)

        XCTAssertFalse(service.setEnabled(true))

        XCTAssertFalse(service.isEnabled)
        XCTAssertFalse(registrar.isRegistered)
        XCTAssertEqual(service.lastError, .registrationFailed)
        XCTAssertEqual(registrar.registerCount, 1)
    }

    func testUnregistrationSuccessUpdatesState() {
        let registrar = FakeLoginItemRegistrar(isRegistered: true)
        let service = LaunchAtLoginService(registrar: registrar)

        XCTAssertTrue(service.setEnabled(false))

        XCTAssertFalse(service.isEnabled)
        XCTAssertFalse(registrar.isRegistered)
        XCTAssertNil(service.lastError)
        XCTAssertEqual(registrar.unregisterCount, 1)
    }

    func testUnregistrationFailureRollsBackState() {
        let registrar = FakeLoginItemRegistrar(isRegistered: true)
        registrar.failUnregister = true
        let service = LaunchAtLoginService(registrar: registrar)

        XCTAssertFalse(service.setEnabled(false))

        XCTAssertTrue(service.isEnabled)
        XCTAssertTrue(registrar.isRegistered)
        XCTAssertEqual(service.lastError, .unregistrationFailed)
        XCTAssertEqual(registrar.unregisterCount, 1)
    }

    func testSameValueIsNoop() {
        let registrar = FakeLoginItemRegistrar(isRegistered: true)
        let service = LaunchAtLoginService(registrar: registrar)

        XCTAssertTrue(service.setEnabled(true))

        XCTAssertTrue(service.isEnabled)
        XCTAssertEqual(registrar.registerCount, 0)
        XCTAssertEqual(registrar.unregisterCount, 0)
        XCTAssertNil(service.lastError)
    }
}
