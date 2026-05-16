import Darwin
import Foundation

enum MemoryProbe {
  /// Current `phys_footprint` of this process in bytes.
  /// Returns 0 on failure (logged to console).
  /// Source: <mach/task_info.h>, task_vm_info_data_t.phys_footprint
  /// Matches the value iOS uses for jetsam / EXC_RESOURCE decisions.
  static func currentPhysFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
    )
    let result: kern_return_t = withUnsafeMutablePointer(to: &info) { ptr in
      ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPtr in
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), reboundPtr, &count)
      }
    }
    guard result == KERN_SUCCESS else {
      NSLog("[MemoryProbe] task_info failed: \(result)")
      return 0
    }
    return info.phys_footprint
  }
}
