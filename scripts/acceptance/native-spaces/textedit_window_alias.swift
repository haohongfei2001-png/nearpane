import ApplicationServices
import Foundation

// An extra AXWindows count is never an input grant. Only the two already-enrolled
// CG numbers may have their file-URL equality checked. No other document is read.
enum TextEditWindowAliases {
    static let limit = 8

    struct Read<Element> {
        let countStatus: AXError
        let reported: Int?
        var copyStatus: AXError?
        var copied: Int?
        var elements: [Element]?
    }
    struct Identity {
        let owner: String
        let number: UInt32
        let role: String
        let subrole: String
    }

    static func read(_ pid: pid_t) -> Read<AXUIElement> {
        let root = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(root, 0.35)
        let key = kAXWindowsAttribute as CFString
        var count = 0
        let status = AXUIElementGetAttributeValueCount(root,key,&count)
        var result = Read<AXUIElement>(countStatus:status,reported:status == .success ? count : nil)
        guard status == .success, (1...limit).contains(count) else { return result }
        var array: CFArray?
        // One sentinel detects a partial result even if GetAttributeValueCount is stale.
        let copied = AXUIElementCopyAttributeValues(root,key,0,limit+1,&array)
        result.copyStatus = copied
        guard copied == .success, let array else { return result }
        let countRead = CFArrayGetCount(array)
        result.copied = countRead
        guard countRead <= limit else { return result }
        let elements = array as [AnyObject]
        guard elements.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() }) else { return result }
        result.elements = elements.map { unsafeBitCast($0,to:AXUIElement.self) }
        return result
    }

    static func prove<Element>(expected: [UInt32]?, interruption: () -> String?, read: () -> Read<Element>,
                               same: (Element,Element) -> Bool, identify: (Element) -> Identity,
                               surfaces: () -> [UInt32]?, between: () -> Void = {}, matchesFile: (Element,Int) -> Bool?) -> (String,[Element]?,[[String:Any]]) {
        var samples = [[String:Any]]()
        var former: Read<Element>?
        var formerState: String?
        var formerOrdered = [Element]()
        let enrolled = expected.flatMap { $0.count == 2 && Set($0).count == 2 && !$0.contains(0) ? $0 : nil }
        for _ in 0..<2 {
            var note: [String:Any] = ["start":ProcessInfo.processInfo.systemUptime]
            if let enrolled { note["enrolledNumbers"] = enrolled }
            func finish(_ state: String) -> (String,[Element]?,[[String:Any]]) {
                note["state"] = state
                note["end"] = ProcessInfo.processInfo.systemUptime
                return (state,nil,samples+[note])
            }
            if let reason = interruption() { return finish(reason) }
            let batch = read()
            note["countAXError"] = batch.countStatus.rawValue
            if let n = batch.reported { note["reported"] = n }
            if let code = batch.copyStatus { note["copyAXError"] = code.rawValue }
            if let n = batch.copied { note["copied"] = n }
            guard batch.countStatus == .success, let reported = batch.reported, (1...limit).contains(reported) else { return finish("countUnqualified") }
            guard batch.copyStatus == .success, let refs = batch.elements, refs.count == batch.copied, refs.count <= limit else { return finish("arrayUnqualified") }
            var unique = [Element](), numbers = [UInt32](), rows = [[String:Any]]()
            for element in refs {
                let id = identify(element)
                let prior = unique.firstIndex { same($0,element) }
                let group = prior ?? unique.count
                var item: [String:Any] = ["ref":group, "owner":id.owner]
                if id.owner == "enrolled" { item["number"] = id.number; item["role"] = id.role; item["subrole"] = id.subrole }
                rows.append(item)
                note["rows"] = rows
                guard id.owner == "enrolled" else { return finish("foreignOrUnreadableOwner") }
                guard id.number > 0 else { return finish("unidentifiedSurface") }
                if let enrolled, !enrolled.contains(id.number) { return finish("additionalAXSurface") }
                if let prior, numbers[prior] != id.number { return finish("oneAXRefMultipleCGIDs") }
                if prior == nil {
                    if numbers.contains(id.number) { return finish("distinctAXRefsShareCGID") }
                    unique.append(element); numbers.append(id.number)
                    if unique.count > 2 { return finish("additionalAXSurface") }
                }
                guard id.role == "window", id.subrole == "standard" else { return finish("nonstandardOrUnresolvedRole") }
            }
            guard let enrolled else { return finish("noPreviouslyBoundPair") }
            guard unique.count == 2, Set(enrolled) == Set(numbers) else { return finish("missingEnrolledSurface") }
            guard let server = surfaces() else { return finish("serverCensusUnavailable") }
            note["serverNumbers"] = Array(server.prefix(limit+1))
            guard server.count <= limit else {
                note["serverCountAtLeast"] = limit+1
                return finish("serverCensusAboveBound")
            }
            note["serverCount"] = server.count
            guard server.count == Set(server).count, !server.contains(0) else { return finish("serverCensusUnavailable") }
            if !Set(server).isSubset(of: Set(enrolled)) { return finish("additionalServerSurface") }
            guard Set(server) == Set(enrolled) else { return finish("missingServerSurface") }
            let ordered = enrolled.compactMap { n in numbers.firstIndex(of:n).map { unique[$0] } }
            if let reason = interruption() { return finish(reason) }
            guard let a = matchesFile(ordered[0],0), let b = matchesFile(ordered[1],1) else { return finish("fileBindingUnreadable") }
            note["fileMatches"] = [a,b]
            guard a && b else { return finish("fileBindingChanged") }
            if let reason = interruption() { return finish(reason) }
            let state = refs.count > 2 ? "duplicateReferences" : reported != refs.count ? "countDrift" : "exactPair"
            if let former {
                guard former.reported == reported, former.copied == batch.copied, formerState == state,
                      let previous = former.elements, zip(previous,refs).allSatisfy(same),
                      zip(formerOrdered,ordered).allSatisfy(same) else { return finish("unstableReads") }
            }
            note["state"] = state
            note["end"] = ProcessInfo.processInfo.systemUptime
            samples.append(note)
            if former != nil { return (state,ordered,samples) }
            former = batch; formerState = state; formerOrdered = ordered
            between()
        }
        return ("unstableReads",nil,samples)
    }
}
