// Read cumulative kernel counters for one already-enrolled process image. No window or GUI access.
import Darwin
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 2, let pid = Int32(args[0]), pid > 1 else { exit(2) }
func identity() -> UInt64? {
    var path = [CChar](repeating:0,count:4096)
    var b = proc_bsdinfo()
    let size = Int32(MemoryLayout.size(ofValue:b))
    guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
          String(decoding:path.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)),as:UTF8.self) == args[1],
          proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&b,size) == size, b.pbi_pid == UInt32(pid), b.pbi_uid == getuid()
    else { return nil }
    return b.pbi_start_tvsec * 1_000_000 + b.pbi_start_tvusec
}
guard let start = identity() else { exit(2) }
var usage = rusage_info_v6()
let rc = withUnsafeMutablePointer(to: &usage) { pointer in
    pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
    }
}
var timebase = mach_timebase_info_data_t()
guard rc == 0, identity() == start, mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom > 0 else { exit(3) }
let counters: [String:UInt64] = [
    "pid":UInt64(pid), "start":start, "energyNanojoules":usage.ri_energy_nj,
    "physicalFootprintBytes":usage.ri_phys_footprint, "userAndSystemTime":usage.ri_user_time + usage.ri_system_time,
    "timebaseNumerator":UInt64(timebase.numer), "timebaseDenominator":UInt64(timebase.denom)
]
print(String(decoding:try JSONEncoder().encode(counters),as:UTF8.self))
