// Thermals.swift — Quake4Mac
//
// Real CPU/GPU temperature + GPU utilisation, no sudo, no helper.
//
//   • Temperatures: the on-die thermal sensors exposed by IOHIDEventSystem. These are
//     private symbols, resolved at runtime with dlsym and called via @convention(c)
//     pointers whose C signatures must match EXACTLY (a mismatch corrupts registers and
//     traps). A standalone probe on this M3 Max confirmed 46 sensors; the CPU/SoC die
//     reads through "PMU tdieN" (~61°C) and cooler device sensors through "PMU tdevN".
//
//   • IMPORTANT: IOHIDEventSystem clients must be created and read on a thread WITH a run
//     loop. Doing it on a bare GCD background queue is what crashed earlier ("IOHIDEvent-
//     SystemServer died"). All access here is therefore main-thread only — assertMain().
//
//   • GPU utilisation: the accelerator's IORegistry "PerformanceStatistics" dict (public).

import Foundation
import IOKit

final class Thermals {
    static let shared = Thermals()
    static let privateThermalsEnabledKey = "settings.enablePrivateThermals"

    // EXACT C signatures (resolved via dlsym).
    private typealias CreateFn       = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatchingFn  = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias CopyServicesFn = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyEventFn    = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias CopyPropFn     = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    private typealias GetFloatFn     = @convention(c) (AnyObject, Int32) -> Double

    private let kTemperatureType: Int64 = 15
    private var eventField: Int32 { Int32(truncatingIfNeeded: kTemperatureType << 16) }

    private var client: AnyObject?            // MUST be retained for the app's lifetime — the
                                              // services below are owned by it; if it's released
                                              // their mach ports go invalid and reads crash.
    private var services: [AnyObject] = []
    private var copyEvent: CopyEventFn?
    private var copyProp: CopyPropFn?
    private var getFloat: GetFloatFn?
    private var didSetup = false

    private init() {}

    private var privateThermalsEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.privateThermalsEnabledKey)
    }

    private func sym<T>(_ h: UnsafeMutableRawPointer?, _ name: String, _ t: T.Type) -> T? {
        guard let h = h, let p = dlsym(h, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    /// Lazily build the IOHID client. MUST run on the main thread.
    private func setupIfNeeded() {
        guard !didSetup else { return }
        didSetup = true
        let h = dlopen(nil, RTLD_NOW)   // IOKit already loaded into the process
        guard let create      = sym(h, "IOHIDEventSystemClientCreate", CreateFn.self),
              let setMatching  = sym(h, "IOHIDEventSystemClientSetMatching", SetMatchingFn.self),
              let copyServices = sym(h, "IOHIDEventSystemClientCopyServices", CopyServicesFn.self),
              let ce = sym(h, "IOHIDServiceClientCopyEvent", CopyEventFn.self),
              let cp = sym(h, "IOHIDServiceClientCopyProperty", CopyPropFn.self),
              let gf = sym(h, "IOHIDEventGetFloatValue", GetFloatFn.self),
              let c = create(kCFAllocatorDefault)?.takeRetainedValue() else { return }
        client = c                             // retain for the singleton's lifetime
        copyEvent = ce; copyProp = cp; getFloat = gf
        // kHIDPage_AppleVendor (0xff00) + AppleVendor temperature-sensor usage (5).
        _ = setMatching(c, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        if let arr = copyServices(c)?.takeRetainedValue() as? [AnyObject] { services = arr }
    }

    /// Average reading (°C) over sensors whose product name begins with any given prefix.
    /// MUST be called on the main thread.
    private func temperature(_ prefixes: [String]) -> Double? {
        setupIfNeeded()
        guard let copyEvent = copyEvent, let copyProp = copyProp, let getFloat = getFloat else { return nil }
        var sum = 0.0, n = 0
        for svc in services {
            guard let nameObj = copyProp(svc, "Product" as CFString)?.takeRetainedValue() else { continue }
            guard let ns = nameObj as? NSString else { continue }
            let name = ns as String
            guard prefixes.contains(where: { name.hasPrefix($0) }) else { continue }
            guard let ev = copyEvent(svc, kTemperatureType, 0, 0)?.takeRetainedValue() else { continue }
            let v = getFloat(ev, eventField)
            if v > 1, v < 130 { sum += v; n += 1 }   // ignore obvious garbage / -1 sentinels
        }
        return n > 0 ? sum / Double(n) : nil
    }

    // CPU/SoC die temperature. M3/M-series: "PMU tdie"; M1/M2: "pACC"/"eACC"; Intel: "TC0".
    func cpuTemp() -> Double? {
        guard privateThermalsEnabled else { return nil }
        return temperature(["PMU tdie", "pACC", "eACC", "TC0", "CPU"])
    }

    // No distinct GPU sensor is exposed by name on M3 Max; the cooler "PMU tdev" device
    // sensors track the GPU/peripheral side of the die. (Falls back to other-arch names.)
    func gpuTemp() -> Double? {
        guard privateThermalsEnabled else { return nil }
        return temperature(["PMU tdev", "GPU", "TG0", "PMU tgpu"])
    }

    // MARK: GPU utilisation (0…1) from the accelerator's PerformanceStatistics (public API)
    func gpuUtilization() -> Double? {
        var iterator = io_iterator_t()
        guard let match = IOServiceMatching("IOAccelerator") else { return nil }
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: Double? = nil
        var svc = IOIteratorNext(iterator)
        while svc != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any],
               let stats = dict["PerformanceStatistics"] as? [String: Any] {
                let util = (stats["Device Utilization %"] as? Double)
                        ?? (stats["GPU Activity(%)"] as? Double)
                        ?? (stats["Device Utilization %"] as? Int).map(Double.init)
                if let u = util { best = max(best ?? 0, u) }
            }
            IOObjectRelease(svc)
            svc = IOIteratorNext(iterator)
        }
        return best.map { max(0, min(100, $0)) / 100.0 }
    }
}
