import AppKit
import Darwin
import NearpaneCore
import Security

// No command-line targeting: one installed Host owns both pipes and the worker can bind only one
// same-user regular application. EOF or parent death discards all AX references.
func executablePath(_ pid: pid_t) -> URL? {
    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
    return URL(fileURLWithPath: String(decoding:path.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)),as:UTF8.self))
}

func verifyParent(_ parent: pid_t) -> Bool {
    guard parent > 1, let own = executablePath(getpid()), let host = executablePath(parent),
          own.lastPathComponent == "NearpaneOrdinaryWindowController",
          own.deletingLastPathComponent().lastPathComponent == "Helpers" else { return false }
    let contents = own.deletingLastPathComponent().deletingLastPathComponent()
    let root = contents.deletingLastPathComponent()
    guard root.pathExtension == "app", contents.lastPathComponent == "Contents",
          Bundle(url:root)?.executableURL?.standardizedFileURL.path == host.standardizedFileURL.path,
          host.lastPathComponent == "NearpaneHost",
          Bundle(url:root)?.bundleIdentifier == "com.holdsnow.nearpane.alpha" else { return false }
    // A clone with new code and copied Info.plist does not validate against the sealed app.
    var signed: SecStaticCode?
    guard SecStaticCodeCreateWithPath(root as CFURL, [], &signed) == errSecSuccess, let signed,
          SecStaticCodeCheckValidity(signed, SecCSFlags(rawValue:kSecCSStrictValidate), nil) == errSecSuccess
    else { return false }
    return true
}

final class Worker {
    let parent: pid_t
    var app: (Int32,UInt64,String)?
    var windowsByID = [ManagedWindowID: WindowMonitor]()
    init(_ parent: pid_t) { self.parent = parent }

    func handle(_ r: OrdinaryWindowRequest) -> OrdinaryWindowReply {
        var reply = OrdinaryWindowReply(r.nonce)
        do {
            try require(getppid() == parent, "调用方已退出。")
            if r.action == .list {
                try require(app == nil && r.id == nil, "一个控制进程仅绑定一次应用。")
                try checkOwner(pid:r.pid, launch:r.launch, bundle:r.bundle)
                app = (r.pid,r.launch,r.bundle)
                let all = try windows(r.pid)
                let numbers = all.map(number)
                let counts = Dictionary(grouping:numbers.compactMap { $0 }, by:{ $0 })
                reply.choices = all.enumerated().map { index,e -> ManagedWindowID? in
                    guard let n = numbers[index], counts[n]?.count == 1 else { return nil }
                    let id = ManagedWindowID(pid:r.pid,launch:r.launch,number:n,element:UUID())
                    windowsByID[id] = WindowMonitor(id:id,bundle:r.bundle,element:e,parent:parent)
                    return id
                }
                try checkOwner(pid:r.pid, launch:r.launch, bundle:r.bundle)
            } else {
                guard let app, app == (r.pid,r.launch,r.bundle), let id = r.id,
                      let m = windowsByID[id] else { throw Refusal("窗口未在本次选择中登记。") }
                switch r.action {
                case .prepare: reply.pair = try m.prepare()
                case .verify:
                    guard let expected = r.expected else { throw Refusal("缺少窗口基线。") }
                    reply.pair = try m.verify(expected)
                case .write:
                    guard let expected = r.expected, let to = r.destination else { throw Refusal("缺少明确的窗口目标。") }
                    (reply.pair,reply.steps) = try m.write(from:expected,to:to)
                case .release: m.stop(); windowsByID.removeValue(forKey:id)
                case .list: break
                }
            }
        } catch { reply.failure = (error as? Refusal)?.message ?? "无法核对系统窗口状态。" }
        return reply
    }
}

let parent = getppid()
guard CommandLine.arguments.count == 1, verifyParent(parent) else { exit(64) }
let worker = Worker(parent)
final class CommandInput {
    let worker: Worker
    var pending = Data()
    init(_ worker: Worker) { self.worker = worker }
    func readable(_ fd: CFFileDescriptor) {
        guard getppid() == worker.parent else { exit(0) }
        var buffer = [UInt8](repeating:0,count:4096)
        let length = Darwin.read(CFFileDescriptorGetNativeDescriptor(fd),&buffer,buffer.count)
        guard length > 0 else { exit(0) }
        pending.append(contentsOf:buffer.prefix(length))
        guard pending.count <= 65_536 else { exit(64) }
        while let end = pending.firstIndex(of:10) {
            guard let command = try? JSONDecoder().decode(OrdinaryWindowRequest.self,from:pending[..<end]) else { exit(65) }
            pending.removeSubrange(...end)
            let reply = worker.handle(command)
            guard var data = try? JSONEncoder().encode(reply) else { exit(70) }
            data.append(10)
            do { try FileHandle.standardOutput.write(contentsOf:data) } catch { exit(0) }
        }
        CFFileDescriptorEnableCallBacks(fd, CFOptionFlags(kCFFileDescriptorReadCallBack))
    }
}

let input = CommandInput(worker)
var inputContext = CFFileDescriptorContext(version:0, info:Unmanaged.passUnretained(input).toOpaque(),
                                           retain:nil, release:nil, copyDescription:nil)
let inputCallback: CFFileDescriptorCallBack = { fd, _, info in
    guard let fd, let info else { exit(70) }
    Unmanaged<CommandInput>.fromOpaque(info).takeUnretainedValue().readable(fd)
}
guard let fd = CFFileDescriptorCreate(nil,STDIN_FILENO,false,inputCallback,&inputContext),
      let source = CFFileDescriptorCreateRunLoopSource(nil,fd,0) else { exit(70) }
CFRunLoopAddSource(CFRunLoopGetCurrent(),source,.defaultMode)
CFFileDescriptorEnableCallBacks(fd,CFOptionFlags(kCFFileDescriptorReadCallBack))
CFRunLoopRun()
