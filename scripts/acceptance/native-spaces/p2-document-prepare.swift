import AppKit
import Security

struct P2InitialActivation: Codable {
    let session:String, intent:String, readerHash:String
    let pid:pid_t, reader:pid_t, allowedFront:pid_t
    let birth:UInt64, readerBirth:UInt64, numbers:[UInt32], hid:[UInt32], expires:Double

    func admits(fixture:pid_t, generation:UInt64, current:[UInt32], hardware:[UInt32], front:pid_t?,
                privateSession:String, now:Double, formalIntentExists:Bool)->Bool {
        !formalIntentExists && privateSession==session && UUID(uuidString:intent) != nil && pid==fixture && birth==generation &&
        numbers==current && numbers.count==2 && Set(numbers).count==2 && !numbers.contains(0) &&
        reader>1 && readerBirth>0 && readerHash.count==40 && readerHash.allSatisfy(\.isHexDigit) &&
        hid.count==13 && hid==hardware && allowedFront>1 && (front==allowedFront || front==pid) && now<expires && expires-now<=2.5
    }
}

func p2ReadInitialFile<T:Decodable>(_ type:T.Type, _ url:URL)->T? {
    let fd=open(url.path,O_RDONLY|O_CLOEXEC|O_NOFOLLOW)
    guard fd>=0 else{return nil}; let file=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
    var st=stat()
    guard fstat(fd,&st)==0,st.st_uid==getuid(),st.st_nlink==1,st.st_mode&S_IFMT==S_IFREG,st.st_mode&0o077==0,
          st.st_size>0,st.st_size<4096,let data=try? file.read(upToCount:4096),Int64(data.count)==st.st_size else{return nil}
    return try? JSONDecoder().decode(type,from:data)
}

struct P2ActiveReply: Codable { let session:String, intent:String, issued:Bool, reason:String }

@MainActor final class P2FirstDocumentActivation {
    private var consumed=false
    func tick(folder:URL,birth:UInt64,windows:[NSWindow]) {
        guard !consumed, windows.count==2,
              let request=p2ReadInitialFile(P2InitialActivation.self,folder.appendingPathComponent("p2-initial-request.json")) else{return}
        consumed=true
        var issued=false,reason="initialActivationEnrollmentChanged"
        defer {
            let reply=P2ActiveReply(session:folder.lastPathComponent,intent:request.intent,issued:issued,reason:reason)
            if let data=try? JSONEncoder().encode(reply) {
                try? data.write(to:folder.appendingPathComponent("p2-initial-result.json"),options:.withoutOverwriting)
            }
        }
        let initial=request.hid
        func newer()->Bool {p2Physical() != initial || NSEvent.pressedMouseButtons != 0}
        guard !newer() else{reason="userSuperseded";return}
        func admitted()->Bool {
            let marker=folder.appendingPathComponent("marker-watch-command.json")
            return request.admits(fixture:getpid(),generation:birth,current:windows.map{UInt32($0.windowNumber)},hardware:p2Physical(),
                                  front:NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                  privateSession:folder.lastPathComponent,now:ProcessInfo.processInfo.systemUptime,
                                  formalIntentExists:FileManager.default.fileExists(atPath:marker.path))
        }
        guard admitted(),NSApp.activationPolicy() == .regular,windows.allSatisfy({$0.isVisible && $0.isOnActiveSpace && !$0.isMiniaturized}),
              p2TrustedObserver(request.reader,request.readerBirth,request.readerHash) else{return}
        guard !newer(),admitted() else{reason=newer() ? "userSuperseded":"initialForegroundOrSetupChanged";return}
        issued=true
        // The fixture performs the normal initial document presentation once. Trial one will choose the other window.
        if NSApp.keyWindow==nil {windows[0].makeKeyAndOrderFront(nil)}
        guard !newer() else{reason="userSuperseded";return}
        NSApp.activate()
        reason="initialAppKitActivationRequested"
    }
}
