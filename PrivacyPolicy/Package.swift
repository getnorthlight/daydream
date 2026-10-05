// swift-tools-version: 5.10
import PackageDescription
let package = Package(name:"PrivacyPolicy",platforms:[.macOS("15.0")],products:[.library(name:"PrivacyPolicy",targets:["PrivacyPolicy"])],targets:[.target(name:"PrivacyPolicy"),.executableTarget(name:"PrivacyChecks",dependencies:["PrivacyPolicy"],path:"Checks")])
