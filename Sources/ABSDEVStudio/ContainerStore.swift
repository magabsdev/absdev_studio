import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class ContainerStore {
    var runtime: ContainerRuntime = .docker { didSet { Task { await refreshAll() } } }
    var area: ContainerArea = .containers
    var containers: [RuntimeContainer] = []
    var stats: [ContainerStats] = []
    var images: [RuntimeImage] = []
    var volumes: [RuntimeVolume] = []
    var networks: [RuntimeNetwork] = []
    var composeProjects: [ComposeProject] = []
    var selection: String?
    var search = ""
    var output = "Container tools ready."
    var systemInfo = ""
    var isBusy = false
    var runtimeAvailable = false
    var executablePath: String {
        didSet { UserDefaults.standard.set(executablePath, forKey: runtime == .docker ? "dockerExecutable" : "appleContainerExecutable") }
    }
    var dockerHost: String {
        didSet { UserDefaults.standard.set(dockerHost, forKey: "dockerHost") }
    }

    init() {
        executablePath = UserDefaults.standard.string(forKey: "dockerExecutable") ?? ""
        dockerHost = UserDefaults.standard.string(forKey: "dockerHost") ?? ""
    }

    func selectRuntime(_ value: ContainerRuntime) {
        runtime = value
        executablePath = UserDefaults.standard.string(forKey: value == .docker ? "dockerExecutable" : "appleContainerExecutable") ?? ""
    }

    func refreshAll() async {
        isBusy = true
        defer { isBusy = false }
        await detectRuntime()
        guard runtimeAvailable else { clearData(); return }
        async let c: Void = refreshContainers()
        async let i: Void = refreshImages()
        async let s: Void = refreshStats()
        async let v: Void = refreshVolumes()
        async let n: Void = refreshNetworks()
        _ = await (c, i, v, n, s)
        if runtime == .docker { await refreshCompose() } else { composeProjects = [] }
    }

    func detectRuntime() async {
        if executablePath.isEmpty {
            let candidates = runtime == .docker
                ? ["/opt/homebrew/bin/docker", "/usr/local/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker"]
                : ["/opt/homebrew/bin/container", "/usr/local/bin/container"]
            executablePath = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) ?? ""
        }
        guard !executablePath.isEmpty else {
            runtimeAvailable = false
            output = "\(runtime.rawValue) executable not found. Set its path in Container System settings."
            return
        }
        let result = await run(runtime == .docker ? "version --format '{{.Client.Version}}'" : "--version")
        runtimeAvailable = result.code == 0
        if !runtimeAvailable { output = result.text }
    }

    func refreshContainers() async {
        let result = await run(runtime == .docker
            ? "ps -a --format '{{json .}}'"
            : "list --format json")
        guard result.code == 0 else { output = result.text; return }
        containers = runtime == .docker ? parseDockerContainers(result.text) : parseAppleContainers(result.text)
    }


    func refreshStats() async {
        guard runtime == .docker else { stats = []; return }
        let result = await run("stats --no-stream --format '{{json .}}'")
        guard result.code == 0 else {
            stats = []
            if !result.text.isEmpty { output = result.text }
            return
        }
        stats = result.text.jsonLines.map { object in
            ContainerStats(
                id: object.string("ID"),
                name: object.string("Name"),
                cpu: object.string("CPUPerc"),
                memoryUsage: object.string("MemUsage"),
                memoryPercent: object.string("MemPerc"),
                networkIO: object.string("NetIO"),
                blockIO: object.string("BlockIO"),
                pids: object.string("PIDs")
            )
        }
    }

    func refreshImages() async {
        let result = await run(runtime == .docker
            ? "image ls --format '{{json .}}'"
            : "image list --format json")
        guard result.code == 0 else { return }
        images = runtime == .docker ? parseDockerImages(result.text) : parseAppleImages(result.text)
    }

    func refreshVolumes() async {
        let result = await run(runtime == .docker ? "volume ls --format '{{json .}}'" : "volume list --format json")
        guard result.code == 0 else { return }
        volumes = runtime == .docker ? parseDockerVolumes(result.text) : parseAppleVolumes(result.text)
    }

    func refreshNetworks() async {
        guard runtime == .docker else { networks = []; return }
        let result = await run("network ls --format '{{json .}}'")
        guard result.code == 0 else { return }
        networks = result.text.jsonLines.compactMap { object in
            RuntimeNetwork(id: object.string("ID"), name: object.string("Name"), driver: object.string("Driver"), scope: object.string("Scope"))
        }
    }

    func refreshCompose() async {
        let result = await run("compose ls --format json")
        guard result.code == 0, let data = result.text.data(using: .utf8), let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { composeProjects = []; return }
        composeProjects = rows.map { ComposeProject(name: $0.string("Name"), status: $0.string("Status"), configFiles: $0.string("ConfigFiles")) }
    }

    func containerAction(_ action: String, id: String) async {
        let command: String
        switch action {
        case "start": command = "start \(quote(id))"
        case "stop": command = "stop \(quote(id))"
        case "restart": command = "restart \(quote(id))"
        case "kill": command = "kill \(quote(id))"
        case "remove": command = "rm -f \(quote(id))"
        default: return
        }
        await execute(command)
        await refreshContainers()
    }

    func inspect(kind: String, id: String) async {
        let prefix = runtime == .docker ? kind : (kind == "container" ? "" : kind)
        let result = await run("\(prefix) inspect \(quote(id))".trimmingCharacters(in: .whitespaces))
        output = result.text
    }

    func logs(container: RuntimeContainer) async {
        let target = container.name.isEmpty ? container.id : container.name
        await execute("logs --timestamps --tail 500 \(quote(target))")
    }

    func openShell(id: String) async {
        guard runtime == .docker else { output = "Interactive shell launching is currently available for Docker containers."; return }
        let script = "tell application \"Terminal\" to do script \"\(executablePath) exec -it \(id) /bin/sh\""
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }

    func removeImage(_ image: RuntimeImage) async {
        let taggedReference = image.repository.isEmpty || image.repository == "<none>"
            ? ""
            : image.repository + (image.tag.isEmpty || image.tag == "<none>" ? "" : ":" + image.tag)
        let target = image.id.isEmpty ? taggedReference : image.id
        guard !target.isEmpty else {
            output = "Unable to delete this image because Docker did not return an image ID or repository reference."
            return
        }
        await execute("image rm --force \(quote(target))")
        await refreshImages()
    }
    func removeVolume(_ name: String) async { await execute("volume rm \(quote(name))"); await refreshVolumes() }
    func removeNetwork(_ id: String) async { await execute("network rm \(quote(id))"); await refreshNetworks() }
    func prune(_ target: String) async { await execute("\(target) prune -f"); await refreshAll() }
    func pullImage(_ reference: String) async { await execute("image pull \(quote(reference))"); await refreshImages() }
    func createVolume(_ name: String) async { await execute("volume create \(quote(name))"); await refreshVolumes() }

    func composeAction(_ action: String, project: ComposeProject) async {
        let file = project.configFiles.split(separator: ",").first.map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? ""
        guard !file.isEmpty else {
            output = "No Docker Compose configuration file was reported for \(project.name)."
            return
        }
        await execute("compose --file \(quote(file)) \(action)")
        if !action.hasPrefix("logs") { await refreshCompose() }
    }

    func systemAction(_ action: String) async {
        let command: String
        if runtime == .docker {
            command = action
        } else {
            command = "system \(action)"
        }
        await execute(command)
        await detectRuntime()
    }

    func loadSystemInfo() async {
        let commands = runtime == .docker ? ["info", "system df", "events --since 1h --until 0s"] : ["system status", "system property list"]
        var sections: [String] = []
        for command in commands {
            let result = await run(command)
            sections.append("$ \(command)\n\(result.text)")
        }
        systemInfo = sections.joined(separator: "\n\n")
    }

    private func execute(_ command: String) async {
        isBusy = true
        output = "$ \(executablePath) \(command)\n"
        let result = await run(command)
        output += result.text
        isBusy = false
    }

    private func run(_ arguments: String) async -> (code: Int32, text: String) {
        let executable = executablePath
        let host = dockerHost
        let isDocker = runtime == .docker
        return await Task.detached {
            func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let process = Process(); let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            let prefix = (!host.isEmpty && isDocker) ? "DOCKER_HOST=\(shellQuote(host)) " : ""
            process.arguments = ["-lc", "\(prefix)\(shellQuote(executable)) \(arguments)"]
            process.standardOutput = pipe; process.standardError = pipe
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (environment["PATH"] ?? "")
            process.environment = environment
            do { try process.run() } catch { return (127, error.localizedDescription) }
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        }.value
    }

    private func clearData() { containers = []; stats = []; images = []; volumes = []; networks = []; composeProjects = [] }
    private nonisolated func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private func parseDockerContainers(_ text: String) -> [RuntimeContainer] {
        text.jsonLines.map { RuntimeContainer(id: $0.string("ID"), name: $0.string("Names"), image: $0.string("Image"), state: $0.string("State"), status: $0.string("Status"), ports: $0.string("Ports")) }
    }
    private func parseDockerImages(_ text: String) -> [RuntimeImage] {
        text.jsonLines.map { RuntimeImage(id: $0.string("ID"), repository: $0.string("Repository"), tag: $0.string("Tag"), size: $0.string("Size"), created: $0.string("CreatedSince")) }
    }
    private func parseDockerVolumes(_ text: String) -> [RuntimeVolume] {
        text.jsonLines.map { RuntimeVolume(name: $0.string("Name"), driver: $0.string("Driver"), mountpoint: $0.string("Mountpoint"), size: "") }
    }
    private func parseAppleContainers(_ text: String) -> [RuntimeContainer] {
        text.jsonObjects.map { row in RuntimeContainer(id: row.string("id", "ID"), name: row.string("configuration.id", "name", "ID"), image: row.string("configuration.image.reference", "image"), state: row.string("status", "state"), status: row.string("status", "state"), ports: row.string("ports")) }
    }
    private func parseAppleImages(_ text: String) -> [RuntimeImage] {
        text.jsonObjects.map { row in RuntimeImage(id: row.string("digest", "id"), repository: row.string("reference", "name"), tag: row.string("tag"), size: row.string("size"), created: row.string("created", "createdAt")) }
    }
    private func parseAppleVolumes(_ text: String) -> [RuntimeVolume] {
        text.jsonObjects.map { row in RuntimeVolume(name: row.string("name"), driver: "Apple", mountpoint: row.string("source", "path"), size: row.string("size")) }
    }
}

private extension Dictionary where Key == String, Value == Any {
    func string(_ keys: String...) -> String {
        for key in keys {
            var value: Any? = self
            for part in key.split(separator: ".") { value = (value as? [String: Any])?[String(part)] }
            if let text = value as? String { return text }
            if let value { return String(describing: value) }
        }
        return ""
    }
}

private extension String {
    var jsonLines: [[String: Any]] {
        split(separator: "\n").compactMap { line in
            guard let data = String(line).data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
    }
    var jsonObjects: [[String: Any]] {
        guard let data = data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else { return jsonLines }
        if let rows = object as? [[String: Any]] { return rows }
        if let dictionary = object as? [String: Any] {
            for key in ["containers", "images", "volumes", "items"] { if let rows = dictionary[key] as? [[String: Any]] { return rows } }
            return [dictionary]
        }
        return []
    }
}
