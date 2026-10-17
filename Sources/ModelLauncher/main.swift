import Darwin
import Foundation
import PlanisphereModel

// Started by the ooo.planisphere.model background item. Reads the private runtime record and
// replaces itself with the bundled model server. With no installed model it exits 0, so launchd
// does not restart it in a loop.
//
// launchd starts a BundleProgram with a relative argv[0] ("Contents/Helpers/planisphere-model"),
// so the server is located beside this executable's real path, never from argv[0].
func executablePath() -> String {
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)
    var buffer = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&buffer, &size) == 0 else { return CommandLine.arguments[0] }
    return String(cString: buffer)
}

let spec = ModelSpec.builtIn
let data = ProcessInfo.processInfo.environment["PLANISPHERE_DATA_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
guard let record = ModelStore.installed(spec: spec, at: .standard(dataDirectory: data)) else { exit(0) }
let server = URL(fileURLWithPath: executablePath()).deletingLastPathComponent().appendingPathComponent("planisphere-model-server")
let arguments = [server.path] + ModelStore.serverArguments(record, spec: spec)
var argv = arguments.map { strdup($0) } + [nil]
execv(server.path, &argv)
FileHandle.standardError.write(Data("planisphere-model: cannot start \(server.path): \(String(cString: strerror(errno)))\n".utf8))
exit(1)
