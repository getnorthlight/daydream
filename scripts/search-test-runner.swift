// CommandLineTools-only fallback. Compiles the same production XCTest test bodies.
import Foundation

#if !canImport(XCTest)
class XCTestCase {
    func setUpWithError() throws {}
    func tearDownWithError() throws {}
}
struct XCTSkip: Error { let reason:String; init(_ reason:String) { self.reason=reason } }
struct UnwrapFailure: Error {}
var assertionFailures=0
func failure(_ message:String,file:StaticString,line:UInt) { assertionFailures += 1; print("FAIL \(file):\(line): \(message)") }
func XCTAssertEqual<T:Equatable>(_ a:@autoclosure () throws -> T,_ b:@autoclosure () throws -> T,_ message:String="",file:StaticString=#filePath,line:UInt=#line) {
    do { let left=try a(), right=try b(); if left != right { failure("\(left) != \(right) \(message)",file:file,line:line) } } catch { failure("\(error)",file:file,line:line) }
}
func XCTAssertTrue(_ value:@autoclosure () throws -> Bool,_ message:String="",file:StaticString=#filePath,line:UInt=#line) {
    do { if try !value() { failure(message,file:file,line:line) } } catch { failure("\(error)",file:file,line:line) }
}
func XCTAssertFalse(_ value:@autoclosure () throws -> Bool,_ message:String="",file:StaticString=#filePath,line:UInt=#line) { XCTAssertTrue(try !value(),message,file:file,line:line) }
func XCTAssertLessThan<T:Comparable>(_ a:@autoclosure () throws -> T,_ b:@autoclosure () throws -> T,file:StaticString=#filePath,line:UInt=#line) { XCTAssertTrue(try a() < b(),file:file,line:line) }
func XCTAssertThrowsError<T>(_ value:@autoclosure () throws -> T,file:StaticString=#filePath,line:UInt=#line) {
    do { _=try value(); failure("expected error",file:file,line:line) } catch {}
}
func XCTUnwrap<T>(_ value:T?) throws -> T { guard let value else { throw UnwrapFailure() }; return value }

@main struct SearchTestRunner {
    static func main() {
        let names=["disabled/offline","private configuration/projection","incremental/restart/rebuild/partial import","outage/import deletion","exclusion/retention/read race","page bounds/filter/source truth","real Typesense HTTP lifecycle","recent canonical actions without writer/index","isolated Typesense preview setup","Never index and reviewed shortening"]
        var skipped=0
        for index in names.indices {
            let test=TypesenseTests(), before=assertionFailures
            do {
                try test.setUpWithError()
                let cases:[() throws -> Void]=[test.testDisabledAndOfflineFallback,test.testPrivateConfigAndProjection,test.testIncrementalRestartRebuildAndPartialImport,test.testDeletionDuringOutageAndDuringImport,test.testExclusionRetentionAndChangedReadFailClosed,test.testPageBoundsFiltersAndUntrustedIndexBody,test.testRealTypesenseLifecycle,test.testRecentActionsWithoutIndexOrWriterCatchup,test.testIsolatedPreviewSetup,test.testNeverRetentionIndexAndReview]
                try cases[index]()
                print("\(before == assertionFailures ? "PASS" : "FAIL") \(names[index])")
            } catch let skip as XCTSkip { skipped += 1; print("SKIP \(skip.reason)") }
            catch { assertionFailures += 1; print("FAIL \(names[index]): \(error)") }
            do { try test.tearDownWithError() } catch { assertionFailures += 1; print("FAIL cleanup") }
        }
        print("Search suite: \(names.count) cases, \(assertionFailures) failures, \(skipped) skipped")
        exit(assertionFailures == 0 ? 0 : 1)
    }
}
#endif
