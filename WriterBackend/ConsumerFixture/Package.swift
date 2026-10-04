// swift-tools-version: 5.10
import PackageDescription
let package=Package(name:"WriterConsumerFixture",platforms:[.macOS(.v13)],dependencies:[.package(path:"..")],targets:[.executableTarget(name:"Consumer",dependencies:[.product(name:"WriterBackend",package:"WriterBackend")])])
