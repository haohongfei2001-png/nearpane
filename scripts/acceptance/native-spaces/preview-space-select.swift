// Select an exactly ordered, signed macOS Mission Control tile through its AXPress.
// The checked occupant set is either empty, these two fixture windows, or the user's registered origin.
import AppKit

private struct Fixture:Decodable {
    let space:UInt64,fixturePID:pid_t,fixtureBirth:UInt64,fixtureHash:String,numbers:[UInt32]
}
private struct Admission:Decodable {let kind:String;let fixture:Fixture?}
private func occupants(_ r:WorkspaceRequest,_ admission:Admission,prior:Set<UInt32>?) throws -> [String:Any]? {
    guard let n=r.target else {throw Refusal("missingBoundDesktop")}
    if admission.kind=="daily-origin" {
        try demand(n==r.original && r.owned.contains(r.current) && !r.owned.contains(n),"originIsNotTheExactProtectedReturnTarget")
        return nil
    }
    try demand(r.owned.contains(n) && n != r.original,"expectedEnrolledOrdinaryDestination")
    if admission.kind=="empty" {return try requireEmpty(n,host:r.hostPID,beforeOverview:prior)}
    guard admission.kind=="two-documents",let f=admission.fixture,f.space==n,f.numbers.count==2,Set(f.numbers).count==2,
          operatorBirth(f.fixturePID)==f.fixtureBirth,let identity=operatorIdentity(f.fixturePID),
          identity.0=="net.example.spaces-document",identity.1==f.fixtureHash else {throw Refusal("fixtureGenerationOrSignatureChanged")}
    let kit=URL(fileURLWithPath:CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent()
    var path=[CChar](repeating:0,count:4096)
    try demand(kit.deletingLastPathComponent().path=="/private/tmp" && kit.lastPathComponent.hasPrefix("nearpane-d01.") &&
               proc_pidpath(f.fixturePID,&path,UInt32(path.count))>0 && String(cString:path)==kit.appendingPathComponent("Field Notes.app/Contents/MacOS/FieldNotes").path,
               "unrecognizedSourceFixtureExecutable")
    guard let report=NPContractMemberReport([NSNumber(value:n)] as CFArray,r.hostPID) as? [String:[String:Any]],
          let row=report[String(n)],row["otherMembers"] as? Int==0,row["unresolved"] as? Int==0,
          let windows=row["ordinary"] as? [[String:NSNumber]],windows.count>=2,windows.count<=3,
          Set(windows.filter{$0["pid"]?.int32Value==f.fixturePID}.compactMap{$0["number"]?.uint32Value})==Set(f.numbers),
          f.numbers.allSatisfy({NPReadWindowSpaces($0) as? [UInt64]==[n]}) else {throw Refusal("exactTwoDocumentForwardOrReverseScopeChanged")}
    let extra=windows.filter{$0["pid"]?.int32Value != f.fixturePID}
    if extra.isEmpty{return nil}
    guard extra.count==1,let prior,let pid=extra[0]["pid"]?.int32Value,let number=extra[0]["number"]?.uint32Value,
          !prior.contains(number),try overviewVisible(),overviewHost(pid)=="com.apple.WindowManager" else {throw Refusal("unexpectedWindowOnTwoDocumentDestination")}
    return ["pid":pid,"number":number,"owner":"com.apple.WindowManager","newSinceOverview":true,"enrolledDocuments":2]
}
@main struct PreviewSystemSelector {
    static func main() {
        var proof:[String:Any]=["setupOnly":true,"productActions":0],issued=false
        do {
            let data=FileHandle.standardInput.readDataToEndOfFile()
            let r=try JSONDecoder().decode(WorkspaceRequest.self,from:data),a=try JSONDecoder().decode(Admission.self,from:data)
            try demand(["empty","two-documents","daily-origin"].contains(a.kind),"invalidPreviewOccupancyClass")
            proof["occupancy"]=a.kind
            try P0MissionControl.select(r,requestedClick:false,issued:&issued,report:&proof,allowOriginal:a.kind=="daily-origin",
                                        validateOccupancy:{try occupants(r,a,prior:$0)})
        } catch {proof["error"]=(error as? Refusal)?.reason ?? "previewSystemSelectionUnavailable"}
        proof["issued"]=issued
        print(String(decoding:try! JSONSerialization.data(withJSONObject:proof,options:.sortedKeys),as:UTF8.self))
    }
}
