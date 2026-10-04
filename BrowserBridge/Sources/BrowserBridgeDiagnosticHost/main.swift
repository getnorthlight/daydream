import Foundation
import BrowserDiagnostic
import Darwin

// Exact public deployment configuration only. Never Keychain or enrollment.
do {
    let args=Array(CommandLine.arguments.dropFirst())
    if args==["--help"] {print("BrowserBridgeDiagnosticHost --setup-directory ABS --diagnostic-directory ABS --extension-id ID --deployment SHA256 --app-public-key BASE64 chrome-extension://ID/");exit(0)}
    guard args.count==11,args[0]=="--setup-directory",args[2]=="--diagnostic-directory",args[4]=="--extension-id",
          args[6]=="--deployment",args[8]=="--app-public-key",args[1].hasPrefix("/"),args[3].hasPrefix("/"),
          let key=Data(base64Encoded:args[9]) else {throw DiagnosticError.invalid}
    let c=try DiagnosticConfiguration.load(setupDirectory:URL(fileURLWithPath:args[1]),diagnosticDirectory:URL(fileURLWithPath:args[3]),
        browser:"chrome",extensionID:args[5],deployment:args[7],trustedAppPublicKey:key)
    try DiagnosticHost.run(configuration:c,callerOrigin:args[10])
} catch {fputs("diagnostic_unavailable\n",stderr);exit(1)}
