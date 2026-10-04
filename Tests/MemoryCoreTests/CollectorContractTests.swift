import XCTest
import HistoryCore

final class CollectorContractTests: XCTestCase {
    func testSecureInputNeverBuffered() {
        var buffer = TextBuffer()
        buffer.append(characters:"fabricated-secret",secureInput:true,captureText:true)
        let result = buffer.drain(); XCTAssertNil(result.text); XCTAssertTrue(result.hadInput)
        buffer.append(characters:"off",secureInput:false,captureText:false); XCTAssertNil(buffer.drain().text)
        buffer.append(characters:"allowed",secureInput:false,captureText:true); XCTAssertEqual(buffer.drain().text,"allowed")
    }
    func testPrivateAndDomainPolicy() {
        let policy = ObservationPolicy(blocklist:[.init(scope:.url,urlDomain:"example.com")])
        XCTAssertNotNil(policy.dropReason(bundleIdentifier:"com.apple.Safari",windowTitle:"Private Browsing",urlDomain:nil))
        XCTAssertFalse(policy.allowsDomain("https://sub.example.com/path"))
        XCTAssertTrue(policy.allowsDomain("notexample.com"))
        XCTAssertTrue(ObservationPolicy.isSecureRole("AXTextField",subrole:"AXSecureTextField"))
    }
    func testEventRedaction() {
        let event = HistoryEvent(id:1,timestamp:Date(),kind:.textInput,key:KeyInfo(text:"synthetic"))
        XCTAssertEqual(event.textFields,["synthetic"]); XCTAssertTrue(event.redactingText().textFields.isEmpty)
        XCTAssertEqual(event.redactingText().id,event.id)
    }
}
