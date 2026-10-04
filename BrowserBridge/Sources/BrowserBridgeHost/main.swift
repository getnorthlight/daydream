import Foundation
import BrowserBridge
import Darwin

let options=Array(CommandLine.arguments.dropFirst())
if options.first=="--reviewed-directory" {
    do {
        guard options.count==7,options[2]=="--keychain-service",options[4]=="--deployment",options[1].hasPrefix("/") else {throw MetadataSetupError.invalid}
        let setup=try MetadataProductionSetup.existing(directory:URL(fileURLWithPath:options[1],isDirectory:true),keychainService:options[3])
        let provider=try setup.resolve(browser:.chrome,expectedDeployment:options[5])
        guard provider.integrationValidated,provider.physicalDeviceValidated else {throw MetadataSetupError.unreviewed}
        let config=try MetadataHostConfiguration(directory:provider.directory,extensionID:provider.pins.extensionID,browser:.chrome)
        try ChromeMetadataHost.run(configuration:config,callerOrigin:options[6])
    } catch {exit(1)}
    exit(0)
}

// Without packaged configuration: no app IPC, recorder, permissions, disk policy, capture, retries
// or environment-variable bypass. Installation/signing/native mapping are NOT
// integrated. The core owner must supply an authenticated app adapter first.
// Merely invoking this executable, including with a forged argv origin, cannot
// enable observation or text collection.
do {
    if try NativeFrames.read(from:.standardInput) != nil {
        let reply=Data(#"{"version":1,"kind":"unavailable","reason":"native_app_not_integrated","textEnabled":false}"#.utf8)
        try FileHandle.standardOutput.write(contentsOf:NativeFrames.encode(reply))
    }
} catch {
    // Do not print received data, URLs, origins or parser errors to Chrome logs.
    exit(1)
}
