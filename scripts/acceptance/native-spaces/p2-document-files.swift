import AppKit

/// Ordinary input enters each document through NSTextView. The delegate persists
/// edits only to the two pre-created, privately owned fixture files.
@MainActor final class FieldDocumentFile: NSObject, NSTextViewDelegate {
    let file: FileHandle, url: URL, seed: String
    var saved = false
    private var previous: String
    init?(folder: URL, slot: Int, session: String) {
        guard (0..<2).contains(slot), UUID(uuidString:session) != nil, folder.lastPathComponent == session else { return nil }
        let kit = folder.deletingLastPathComponent()
        guard let canonical = realpath(folder.path,nil) else { return nil }
        let full = String(cString:canonical); free(canonical)
        var dirs = stat()
        guard full == "/private/tmp/"+kit.lastPathComponent+"/"+session, kit.lastPathComponent.hasPrefix("nearpane-d01."),
              [kit,folder].allSatisfy({ lstat($0.path,&dirs) == 0 && dirs.st_uid == getuid() && dirs.st_mode & S_IFMT == S_IFDIR && dirs.st_mode & 0o077 == 0 }),
              ["HOME","CFFIXED_USER_HOME"].allSatisfy({ ProcessInfo.processInfo.environment[$0] == folder.appendingPathComponent("home").path }) else { return nil }
        let name = slot == 0 ? "A" : "B"
        self.url=folder.appendingPathComponent(name+".txt")
        let fd=open(url.path,O_RDWR|O_NOFOLLOW|O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        var st=stat()
        guard fstat(fd,&st) == 0, st.st_uid == getuid(), st.st_mode & S_IFMT == S_IFREG, st.st_nlink == 1, st.st_mode & 0o077 == 0,
              st.st_size > 0, st.st_size < 128, let source=try? handle.read(upToCount:128),
              let text=String(data:source,encoding:.utf8), text == "Field Notes "+name+" "+session+"\n" else { return nil }
        self.file=handle; self.seed=text; self.previous=text
        super.init()
        saved=true
    }
    func textDidChange(_ notification: Notification) {
        guard let editor=notification.object as? NSTextView else { return }
        let text=editor.string
        guard text.utf8.count <= 4096, text.hasPrefix(previous),
              FieldMarkerWitness.active?.enrolledDocumentEdit(String(text.dropFirst(previous.count)))==true else { saved=false; return }
        let data=Data(text.utf8)
        do {
            try file.seek(toOffset:0)
            try file.write(contentsOf:data)
            try file.truncate(atOffset:UInt64(data.count))
            try file.synchronize()
            previous=text; saved=true
        } catch { saved=false }
    }
}
