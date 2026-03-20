import Foundation
import PackagePlugin

@main
struct CopyResourcesPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        // Locate the artifact bundle binaries
        let resourceNames = ["vminitd", "vmexec", "vmlinux", "pre-init"]

        // The output directory where we'll place the resources
        let outputDir = context.pluginWorkDirectoryURL.appending(path: "Resources")

        var commands: [Command] = []

        for name in resourceNames {
            let tool = try context.tool(named: name)
            let outputFile = outputDir.appending(path: name)

            commands.append(.prebuildCommand(
                displayName: "Copy \(name) to Resources",
                executable: URL(fileURLWithPath: "/bin/cp"),
                arguments: [tool.url.path(), outputFile.path()],
                outputFilesDirectory: outputDir
            ))
        }

        return commands
    }
}
