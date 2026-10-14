import Darwin
import Foundation
import PlanisphereModel

// Started by the ooo.planisphere.model background item. Reads the private runtime record and
// replaces itself with the bundled model server. With no installed model it exits 0, so launchd
// does not restart it in a loop.
let spec = ModelSpec.builtIn
guard let record = ModelStore.installed(spec: spec, at: .standard()) else { exit(0) }
let server = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    .deletingLastPathComponent().appendingPathComponent("planisphere-model-server")
let arguments = [server.path] + ModelStore.serverArguments(record, spec: spec)
var argv = arguments.map { strdup($0) } + [nil]
execv(server.path, &argv)
FileHandle.standardError.write(Data("planisphere-model: cannot start \(server.path): \(String(cString: strerror(errno)))\n".utf8))
exit(1)
