// Metadata only. Surfaces rendered by the signed compositor are not ordinary documents.
// The actual screenshot paths independently reject occlusion and include exactly their enrolled CG windows.
import AppKit
import ApplicationServices
import Security

enum PreviewCensus {
    typealias Row=[String:Any]
    // Foundation rewrites /private/tmp to /tmp on macOS. Accept only these two spellings
    // of the same POSIX-resolved object, never an arbitrary symlink into or out of the kit.
    static func ownedTemporaryURL(_ spelling:String)->URL? {
        guard spelling.hasPrefix("/private/tmp/") || spelling.hasPrefix("/tmp/"),
              let resolved=realpath(spelling,nil) else {return nil}
        defer {free(resolved)}
        let exact=String(cString:resolved)
        guard exact.hasPrefix("/private/tmp/"),spelling==exact || (spelling.hasPrefix("/tmp/") && "/private"+spelling==exact) else{return nil}
        var st=stat()
        guard lstat(exact,&st)==0,st.st_uid==getuid(),st.st_mode & S_IFMT==S_IFDIR,st.st_mode & 0o077==0 else{return nil}
        return URL(fileURLWithPath:exact,isDirectory:true)
    }
    static func kit(_ executable:String)->URL? {
        let raw=URL(fileURLWithPath:executable).deletingLastPathComponent().path
        guard let u=ownedTemporaryURL(raw),u.deletingLastPathComponent().path=="/private/tmp",
              u.lastPathComponent.hasPrefix("nearpane-d01.") else{return nil}
        return u
    }
    static func prop(_ el:AXUIElement,_ name:String)->CFTypeRef? {
        var v:CFTypeRef?
        return AXUIElementCopyAttributeValue(el,name as CFString,&v) == .success ? v:nil
    }
    static func path(_ p:pid_t)->String? {
        var bytes=[CChar](repeating:0,count:4096)
        return proc_pidpath(p,&bytes,UInt32(bytes.count))>0 ? String(cString:bytes):nil
    }
    // System surfaces can composite other windows. They are admitted for window
    // census only and never become an included content-filter or a physical source.
    static let appleServices=[
        "/System/Library/CoreServices/WindowManager.app/Contents/MacOS/WindowManager":("com.apple.WindowManager","appleWindowManager"),
        "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer":("com.apple.WindowServer","appleWindowServer"),
        "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock":("com.apple.dock","appleDock"),
        "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter":("com.apple.controlcenter","appleControlCenter")]
    static func apple(_ p:pid_t)->String? {
        guard let path=path(p),let (id,category)=appleServices[path] else{return nil}
        var req:SecRequirement?,code:SecCode?
        guard SecRequirementCreateWithString(("anchor apple and identifier \""+id+"\"") as CFString,[],&req)==errSecSuccess,let req,
              SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributePid:NSNumber(value:p)] as CFDictionary,[],&code)==errSecSuccess,let code,
              SecCodeCheckValidity(code,[],req)==errSecSuccess else{return nil}
        return category
    }
    static func windowRows(_ number:UInt32)->[Row]? {
        guard let ids=CFArrayCreateMutable(nil,1,nil),let value=UnsafeRawPointer(bitPattern:UInt(number)) else{return nil}
        CFArrayAppendValue(ids,value)
        return CGWindowListCreateDescriptionFromArray(ids) as? [Row]
    }
    static func otherAppleID(_ pid:pid_t)->String? {
        guard let path=path(pid),path.hasPrefix("/System/Library/") || path.hasPrefix("/usr/libexec/") else{return nil}
        var req:SecRequirement?,code:SecCode?,staticCode:SecStaticCode?,info:CFDictionary?
        guard SecRequirementCreateWithString("anchor apple" as CFString,[],&req)==errSecSuccess,let req,
              SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributePid:NSNumber(value:pid)] as CFDictionary,[],&code)==errSecSuccess,let code,
              SecCodeCheckValidity(code,[],req)==errSecSuccess,SecCodeCopyStaticCode(code,[],&staticCode)==errSecSuccess,let staticCode,
              SecCodeCopySigningInformation(staticCode,SecCSFlags(rawValue:kSecCSSigningInformation),&info)==errSecSuccess,
              let id=(info as? Row)?[kSecCodeInfoIdentifier as String] as? String,id.hasPrefix("com.apple.") else{return nil}
        return id
    }
    static func disposition(signedCompositor:Bool,fixture:Bool,validShape:Bool,explicitlyNonstandard:Bool,
                            absentFromFixtureAX:Bool,unpresented:Bool,thinOffscreen:Bool)->String {
        if signedCompositor && validShape {return "signedCompositor"}
        if fixture && validShape && (explicitlyNonstandard || (absentFromFixtureAX && unpresented)) {return "enrolledNonDocument"}
        if !fixture && thinOffscreen {return "unverifiedThinOffscreen"}
        return "unverifiedOrdinary"
    }
    static func ownedAX(_ element:AXUIElement?,pid:pid_t)->AXUIElement? {
        var actual:pid_t=0
        guard let element,AXUIElementGetPid(element,&actual) == .success,actual==pid else{return nil}
        return element
    }
    struct Extra {
        let owner:String, category:String
        let details:Row
        var admitted:Bool {category=="signedCompositor" || category=="enrolledNonDocument"}
    }
    // Only the enrolled fixture's own AX metadata is consulted. No title, other
    // application's AX object, image or content participates in classification.
    static func extra(pid:pid_t, fixture:pid_t, rect:CGRect, on:Bool, drawn:Bool, singleSpace:Bool,
                      publicNow:Bool?, publicAll:Bool?, axCount:Int?, role:String?, subrole:String?,
                      strict:Bool=false)->Extra {
        let service=apple(pid),isFixture=pid==fixture
        let owner=service ?? (isFixture ? "fixtureAuxiliary" : otherAppleID(pid) ?? "otherOwner")
        let standard=role==kAXWindowRole && subrole==kAXStandardWindowSubrole
        let valid=rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite && rect.width>0 && rect.height>0
        let nonePublic=publicNow==false && publicAll==false
        let thin=rect.height>0 && rect.height<=48 && rect.width>=rect.height*8
        let kind=disposition(signedCompositor:service != nil,fixture:isFixture && (!strict || singleSpace),validShape:valid,
                             explicitlyNonstandard:axCount==1 && subrole != nil && !standard && (!strict || (role==kAXWindowRole && subrole != kAXStandardWindowSubrole)),
                             absentFromFixtureAX:!strict && axCount==0,unpresented:(!on || !drawn) && nonePublic,
                             thinOffscreen:thin && !on && !drawn && nonePublic)
        let detail:Row=["owner":owner,"category":kind,"onscreen":on,"drawn":drawn,"thin":thin,"singleSpace":singleSpace,
                        "inPublicCurrent":publicNow as Any? ?? NSNull(),"inPublicAll":publicAll as Any? ?? NSNull(),
                        "fixtureAXStandard":isFixture ? standard as Any:NSNull(),
                        "fixtureAXWindowRole":isFixture ? (role==kAXWindowRole) as Any:NSNull(),
                        "fixtureAXSubroleReported":isFixture ? (subrole != nil) as Any:NSNull()]
        return Extra(owner:owner,category:kind,details:detail)
    }
    static func report(_ space:UInt64,host:pid_t,fixture:pid_t,expected:[UInt32],visible:Bool,strictExtras:Bool=false,enrolledOwners:[UInt32:pid_t]?=nil)->Row {
        var out:Row=["admitted":false,"expected":expected,"unknown":0]
        func fail(_ why:String)->Row {out["reason"]=why;return out}
        guard NPReadOnlySpacesOpen()==1,let record=(NPContractMemberReport([NSNumber(value:space)] as CFArray,host) as? [String:Row])?[String(space)],
              let ordinary=record["ordinary"] as? [[String:NSNumber]],ordinary.count<=128,
              let forward=NPReadCatalogSpaceWindowNumbers(space) as? [UInt32] else{return fail("scopedMembershipUnavailable")}
        out["rawOrdinary"]=ordinary.count;out["unresolved"]=record["unresolved"];out["otherLayers"]=record["otherMembers"]
        if fixture>1 {
            out["fixtureIsFrontmost"]=NSWorkspace.shared.frontmostApplication?.processIdentifier==fixture
            out["fixtureAppKitActive"]=NSRunningApplication(processIdentifier:fixture)?.isActive as Any? ?? NSNull()
        }
        let numbers=Set(expected)
        guard numbers.count==expected.count && (numbers.isEmpty || fixture>1) else{return fail("invalidEnrolledFixtureNumbers")}
        let owners=enrolledOwners ?? Dictionary(uniqueKeysWithValues:expected.map{($0,fixture)})
        guard Set(owners.keys)==numbers,owners.values.allSatisfy({$0>1}),enrolledOwners==nil || owners.isEmpty || owners.values.contains(fixture)
        else{return fail("invalidEnrolledOwners")}
        var cohort=Set(owners.values)
        if fixture>1 {cohort.insert(fixture)}
        let publicNow=NSWindow.windowNumbers(options:.allApplications).map{Set($0.map(\.uint32Value))}
        let publicAll=NSWindow.windowNumbers(options:[.allApplications,.allSpaces]).map{Set($0.map(\.uint32Value))}
        var windowsByOwner=[pid_t:[AXUIElement]]()
        for pid in cohort {
            let ax=AXUIElementCreateApplication(pid)
            _=AXUIElementSetMessagingTimeout(ax,0.4)
            windowsByOwner[pid]=prop(ax,kAXWindowsAttribute) as? [AXUIElement]
        }
        var seen=Set<UInt32>(),expectedRows=[Row](),extra=[String:Int](),unknown=0,details=[Row]()
        for member in ordinary {
            guard let p=member["pid"]?.int32Value,let n=member["number"]?.uint32Value,let individual=windowRows(n),individual.count==1,
                  let cg=individual.first,cg[kCGWindowNumber as String] as? UInt32==n,cg[kCGWindowOwnerPID as String] as? pid_t==p,
                  cg[kCGWindowLayer as String] as? Int==0,let bounds=cg[kCGWindowBounds as String] as? NSDictionary,
                  let rect=CGRect(dictionaryRepresentation:bounds),let reverse=NPReadWindowSpaces(n) as? [UInt64],reverse.contains(space),forward.contains(n)
            else {
                unknown+=1;extra["incompleteRow",default:0]+=1
                if details.count<8 {
                    let n=member["number"]?.uint32Value,p=member["pid"]?.int32Value
                    details.append(["category":"incompleteRow","enrolled":n.map{numbers.contains($0)} ?? false,
                                    "owner":p.flatMap{ $0==fixture ? "fixture" : apple($0) } ?? "otherOwner",
                                    "independentForward":n.map{forward.contains($0)} ?? false])
                };continue
            }
            let on=cg[kCGWindowIsOnscreen as String] as? Bool==true
            let drawn=(cg[kCGWindowAlpha as String] as? Double ?? 0)>0 && rect.width>1 && rect.height>1
            let windows=windowsByOwner[p]
            let list=windows?.filter{NPReadAXWindowNumber($0)==n}
            let item=list?.count==1 ? (strictExtras ? ownedAX(list?.first,pid:p):list?.first):nil
            let role=item.flatMap{prop($0,kAXRoleAttribute) as? String},subrole=item.flatMap{prop($0,kAXSubroleAttribute) as? String}
            let standard=role==kAXWindowRole && subrole==kAXStandardWindowSubrole
            let validShape=rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width>0 && rect.height>0
            if owners[n]==p {
                let direct=standard && item.flatMap{prop($0,kAXMinimizedAttribute) as? Bool}==false && item.flatMap{prop($0,kAXModalAttribute) as? Bool} != true
                let accepted=validShape && reverse==[space] && (!visible || (direct && on && drawn))
                if accepted {seen.insert(n)}
                expectedRows.append(["number":n,"forward":true,"reverse":reverse,"publicCurrent":publicNow?.contains(n) as Any? ?? NSNull(),
                    "publicAll":publicAll?.contains(n) as Any? ?? NSNull(),"axListCount":windows?.count as Any? ?? NSNull(),
                    "axStandard":standard,"cgOnscreen":on,"drawn":drawn,"bounds":[rect.minX,rect.minY,rect.width,rect.height],"accepted":accepted])
                continue
            }
            let evidence=Self.extra(pid:p,fixture:cohort.contains(p) ? p:fixture,rect:rect,on:on,drawn:drawn,singleSpace:reverse==[space],
                                    publicNow:publicNow?.contains(n),publicAll:publicAll?.contains(n),
                                    axCount:list?.count,role:role,subrole:subrole,strict:strictExtras)
            if !evidence.admitted {unknown+=1}
            extra[evidence.owner+"/"+evidence.category,default:0]+=1
            if details.count<8 {details.append(evidence.details)}
        }
        out["expectedProven"]=seen==numbers;out["expectedEvidence"]=expectedRows;out["extraClasses"]=extra;out["extraEvidence"]=details;out["unknown"]=unknown
        let other=record["otherMembers"] as? Int,otherRows=record["otherDetails"] as? [Row]
        let knownLayers=other==0 || (other != nil && otherRows?.count==other && otherRows?.allSatisfy{item in
            guard let p=item["pid"] as? pid_t else{return false};return p==host || apple(p) != nil
        }==true)
        if let otherRows {
            out["otherLayerEvidence"]=otherRows.prefix(8).map{item -> Row in
                let pid=item["pid"] as? pid_t,owner=pid.flatMap{$0==host ? "installedHost":apple($0) ?? otherAppleID($0)} ?? "otherOwner"
                return ["owner":owner,"layer":item["layer"] ?? NSNull(),"onscreen":item["onscreen"] ?? NSNull(),
                        "visibleQuery":item["visibleQuery"] ?? NSNull(),"exclusive":item["reverse"] as? [UInt64]==[space]]
            }
        }
        out["otherLayersAdmitted"]=knownLayers
        out["admitted"]=record["unresolved"] as? Int==0 && knownLayers && unknown==0 && seen==numbers
        if out["admitted"] as? Bool != true {out["reason"]=seen==numbers ? "unverifiedExtraWindowOrMembership":"enrolledForwardReverseAXOrVisibilityIncomplete"}
        return out
    }
}
