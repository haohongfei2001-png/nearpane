// This program accepts three independently journalled ordinary Space identities.
// Its sole input is AXPress on the corresponding button in the installed product.
let args=CommandLine.arguments
if args.count==10, let pid=Int32(args[1]), let app=host, app.processIdentifier==pid,
   app.bundleURL?.standardizedFileURL.path=="/Applications/Nearpane.app",runningCodeHash(pid)==args[2],
   let from=UInt64(args[4]),let target=UInt64(args[5]),target != from,let coords=spaces,coords.count==1,
   coords[0]["scope"] as? String==args[3],coords[0]["current"] as? UInt64==from,
   let topology=coords[0]["records"] as? [Object] {
    var leased=Set<UInt64>()
    for pair in args[6...8] {
        let fields=pair.split(separator:"=")
        if fields.count==2, let id=UInt64(fields[0]),topology.contains(where:{$0["id"] as? UInt64==id && $0["uuid"] as? String==String(fields[1]) && $0["type"] as? Int==0}) {leased.insert(id)}
    }
    let anchorParts=args[9].split(separator:",")
    let syntheticSource = anchorParts.count==3 && anchorParts[0]=="anchor" && Int32(anchorParts[1])==front?.processIdentifier && front?.bundleIdentifier=="net.example.spaces-document" && (front?.processIdentifier).flatMap { focusedNumber($0) }==UInt32(anchorParts[2])
    let expected="native-space-row:\(args[3]):\(target)"
    if leased.count==3,leased.contains(target), leased.contains(from) || args[9]=="setup" || syntheticSource, let nodes=Sidebar(app,rows:rows).controls[expected],nodes.count==1,
       value(nodes[0],kAXRoleAttribute) as? String==kAXButtonRole,value(nodes[0],kAXEnabledAttribute) as? Bool==true {
        let result=AXUIElementPerformAction(nodes[0],kAXPressAction as CFString)
        print("{\"issued\":true,\"axError\":\(result.rawValue)}")
    } else {print("{\"issued\":false,\"reason\":\"unique enabled signed Host row did not match leased identities\"}")}
} else {print("{\"issued\":false,\"reason\":\"active Space or installed Host changed before press\"}")}
