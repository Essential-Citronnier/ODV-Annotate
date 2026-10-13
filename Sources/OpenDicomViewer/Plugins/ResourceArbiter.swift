// ResourceArbiter.swift
// OpenDicomViewer
//
// Admission control for plugin memory. Decides whether a plugin may start, and
// when it may not, which resident plugins to evict to make room.
// PLUGIN_PROTOCOL.md invariant 4 is what gives this teeth: a plugin declares
// its peak resident memory, and the host holds it to that declaration.
// Licensed under the MIT License. See LICENSE for details.

import Foundation
import Darwin

// MARK: - Memory observation

/// A snapshot of machine memory, in gibibytes.
///
/// Gibibytes rather than gigabytes because `physicalMemory` reports powers of
/// two: a "16 GB" Mac returns exactly 16 GiB, and the manifest's `ram_gb`
/// figures are quoted on the same scale.
struct MemoryStatus: Equatable, Sendable {
    let physicalGB: Double
    /// Memory the machine could hand out now without paging or compressing.
    let availableGB: Double

    static let bytesPerGB: Double = 1_073_741_824
}

/// Reads machine memory. Separated from the policy so that tests drive the
/// policy with fixed numbers and never depend on the memory pressure of the
/// machine running them.
enum MemoryProbe {

    /// Page counters the availability estimate is computed from. A plain
    /// value so the arithmetic is testable without a live kernel.
    struct VMCounters: Equatable, Sendable {
        var inactive: UInt64 = 0
        var wired: UInt64 = 0
        var purgeable: UInt64 = 0
        /// Anonymous (process-private) pages, active and inactive.
        var internalPages: UInt64 = 0
        /// File-backed pages, which the kernel can drop and re-read.
        var externalPages: UInt64 = 0
        /// Pages occupied by the compressor itself.
        var compressor: UInt64 = 0
    }

    /// Live reading from the Mach VM statistics.
    ///
    /// `host_statistics64` is the only interface that exposes the compressor
    /// page count, and the compressor is precisely where a mis-admitted model
    /// shows up first on Apple Silicon; `os_proc_available_memory` is iOS-only
    /// and the `vm_stat` tool would mean parsing a subprocess.
    static func system() -> MemoryStatus {
        let physicalBytes = Double(ProcessInfo.processInfo.physicalMemory)
        let physicalGB = physicalBytes / MemoryStatus.bytesPerGB

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
                host_statistics64(mach_host_self(), host_flavor_t(HOST_VM_INFO64), raw, &count)
            }
        }

        guard status == KERN_SUCCESS else {
            // The probe should never fail on a healthy system. If it does, assume
            // half the machine is spoken for: pessimistic enough to keep the
            // arbiter from over-admitting, generous enough to stay usable.
            return MemoryStatus(physicalGB: physicalGB, availableGB: physicalGB / 2)
        }

        let counters = VMCounters(
            inactive: UInt64(stats.inactive_count),
            wired: UInt64(stats.wire_count),
            purgeable: UInt64(stats.purgeable_count),
            internalPages: UInt64(stats.internal_page_count),
            externalPages: UInt64(stats.external_page_count),
            compressor: UInt64(stats.compressor_page_count))
        return MemoryStatus(
            physicalGB: physicalGB,
            availableGB: availableGB(counters, pageSize: Double(vm_kernel_page_size),
                                     physicalGB: physicalGB))
    }

    /// Memory a newcomer can have without pushing the active working set of
    /// anything else into the compressor.
    ///
    /// Counted as committed: wired pages, the compressor's own pages, and
    /// anonymous memory in active use. Counted as available: free pages,
    /// file-backed cache (dropped and re-read on demand), purgeable pages (the
    /// kernel discards them under pressure rather than paging anyone out), and
    /// inactive anonymous pages.
    ///
    /// Inactive anonymous memory is what the earlier estimate missed. It is
    /// memory a process allocated and has not touched recently -- a closed
    /// tab's heap, a backgrounded app -- and macOS compresses or swaps it
    /// before it touches anything active. Counting it as consumed made a Mac
    /// that had been up a while look full and refused models that load
    /// comfortably. The kernel does not split the inactive queue by kind, so
    /// the anonymous share is bounded from below as `inactive - external`
    /// (every inactive file page is also an external page): the estimate can
    /// only err on the low side.
    ///
    /// Active anonymous memory is deliberately not treated as compressible,
    /// even though the compressor would take it: squeezing another process's
    /// working set to make room is the thrashing this arbiter exists to
    /// prevent. The user can still overrule a headroom refusal per start
    /// (`AdmissionDecision.refuseLiveHeadroom`).
    static func availableGB(_ c: VMCounters, pageSize: Double, physicalGB: Double) -> Double {
        let inactiveAnonymous = c.inactive > c.externalPages ? c.inactive - c.externalPages : 0
        let anonymous = Double(c.internalPages)
        let reclaimable = min(anonymous, Double(c.purgeable) + Double(inactiveAnonymous))
        let usedPages = (anonymous - reclaimable) + Double(c.wired) + Double(c.compressor)
        let usedGB = max(0, usedPages * pageSize) / MemoryStatus.bytesPerGB
        return min(physicalGB, max(0, physicalGB - usedGB))
    }

    /// A fixed reading, for tests and for previews.
    static func fixed(physicalGB: Double, availableGB: Double) -> @Sendable () -> MemoryStatus {
        { MemoryStatus(physicalGB: physicalGB, availableGB: availableGB) }
    }
}

// MARK: - Residency

/// A plugin the arbiter is accounting for: either already resident, or the one
/// asking to become resident.
struct PluginResidency: Equatable, Sendable {
    let pluginID: String
    /// The manifest's `ram_gb`. The arbiter budgets against the declaration, not
    /// against measured usage, so that a plugin which under-declares is starved
    /// rather than silently allowed to thrash the machine (invariant 4).
    let declaredRamGB: Double
    /// Drives eviction order. Least recently used goes first.
    let lastUsed: Date
    /// False while a plugin is mid-invocation or holds open sessions. Such a
    /// plugin blocks admission instead of being evicted out from under work the
    /// user is waiting on.
    let isEvictable: Bool

    init(pluginID: String, declaredRamGB: Double, lastUsed: Date = Date(), isEvictable: Bool = true) {
        self.pluginID = pluginID
        self.declaredRamGB = declaredRamGB
        self.lastUsed = lastUsed
        self.isEvictable = isEvictable
    }
}

// MARK: - Decision

enum AdmissionDecision: Equatable, Sendable {
    /// There is room now.
    case admit
    /// There is room once these plugins stop, in the order given.
    case evictThenAdmit([String])
    /// There is no arrangement of the resident set that fits the declared
    /// budget. Never overridable: the request is larger than the plugin
    /// subsystem's share of physical memory, or work in flight holds that share.
    case refuse(requiredGB: Double, availableGB: Double)
    /// The declared budget fits (after `evictions`), but the machine does not
    /// have the memory free right now. The user may start anyway: the live
    /// reading is an estimate, and the cost of being wrong is paging, not a
    /// request the machine can never satisfy.
    case refuseLiveHeadroom(requiredGB: Double, availableGB: Double, evictions: [String])

    var isAdmitted: Bool {
        switch self {
        case .admit, .evictThenAdmit: return true
        case .refuse, .refuseLiveHeadroom: return false
        }
    }

    /// Whether the user may overrule this refusal.
    var isOverridable: Bool {
        if case .refuseLiveHeadroom = self { return true }
        return false
    }

    /// The decision to act on when the user chose "Start anyway": admit after
    /// the evictions the budget needs. Anything but a headroom refusal is
    /// returned unchanged, so a budget refusal can never be overridden.
    var overridden: AdmissionDecision {
        guard case .refuseLiveHeadroom(_, _, let evictions) = self else { return self }
        return evictions.isEmpty ? .admit : .evictThenAdmit(evictions)
    }

    /// Plugin identifiers the caller must stop before proceeding.
    var evictions: [String] {
        if case .evictThenAdmit(let ids) = self { return ids }
        return []
    }
}

/// Why a request was refused, in a form the store can show verbatim.
extension AdmissionDecision {
    var refusalError: PluginError? {
        switch self {
        case .refuse(let required, let available):
            return .insufficientMemory(required: required, available: available)
        case .refuseLiveHeadroom(let required, let available, _):
            return .insufficientLiveMemory(required: required, available: available)
        case .admit, .evictThenAdmit:
            return nil
        }
    }
}

// MARK: - Arbiter

/// Decides which plugins may hold memory at the same time.
///
/// The policy is two simultaneous constraints, both of which must hold after
/// any evictions:
///
/// 1. **Declared budget.** The sum of declared RAM across everything resident
///    must fit within `residentFraction` of physical memory. This term is
///    deterministic — it does not move with whatever the machine happens to be
///    doing — which is what makes concurrency behaviour reproducible and
///    testable, and it is the term that decides the 16 GB case.
/// 2. **Live headroom.** The incoming plugin's declared RAM must fit in memory
///    the machine can actually hand out right now, less a safety margin.
///    Evicting a resident plugin returns its declared RAM to this pool.
///
/// The first constraint keeps the host from co-locating models that nominally
/// fit but leave nothing for the viewer itself; the second keeps it from
/// admitting anything at all when the user has the machine loaded with other
/// work. Neither alone is sufficient.
///
/// Everything here is a pure function of (demand, resident set, memory reading).
/// `probe` is injectable, so the tests exercise the policy without allocating a
/// byte.
struct ResourceArbiter: Sendable {

    /// Share of physical memory the plugin subsystem may claim in aggregate.
    ///
    /// Half. On a 16 GiB machine that is 8 GiB, which is what forces the case
    /// this design exists for: Gemma resident at 5 GB plus TotalSegmentator's
    /// 3.5 GB is 8.5 GB and does not fit, so Gemma is evicted for the duration
    /// of the segmentation instead of the two of them fighting over the
    /// compressor. The other half is not slack — it is macOS, the viewer, and a
    /// decompressed CT volume, none of which declare themselves to the arbiter.
    var residentFraction: Double

    /// Share of physical memory a one-shot job may claim when it cannot fit
    /// `residentFraction` at all.
    ///
    /// The co-residency share exists to stop models that each nominally fit
    /// from crowding out the viewer and each other. A one-shot is different in
    /// kind: it is transient, it owns no resident slot, and it can run with
    /// everything evictable stopped. Holding it to half the machine made
    /// TotalSegmentator's measured 23.5 GB peak unrunnable below 47 GB of
    /// physical memory -- every 32 GB Mac included -- while that same machine
    /// can host the job alone. A job too large for the shared share is
    /// therefore budgeted against this larger one instead, and still has to
    /// clear live headroom, so a loaded machine continues to refuse it.
    ///
    /// Only jobs too large for the shared share take this path, so everything
    /// that fits the shared share behaves exactly as before: on 16 GB, Gemma is
    /// still evicted for a 3.5 GB job rather than the two being squeezed into
    /// three quarters of the machine.
    var oneShotFraction: Double

    /// Held back from live availability so that admitting a plugin never takes
    /// the machine to the edge. Sized to roughly one large series plus the
    /// window server's working set.
    var safetyMarginGB: Double

    var probe: @Sendable () -> MemoryStatus

    init(residentFraction: Double = 0.5,
         oneShotFraction: Double = 0.75,
         safetyMarginGB: Double = 2.0,
         probe: @escaping @Sendable () -> MemoryStatus = { MemoryProbe.system() }) {
        self.residentFraction = residentFraction
        self.oneShotFraction = max(oneShotFraction, residentFraction)
        self.safetyMarginGB = safetyMarginGB
        self.probe = probe
    }

    // MARK: Budgets

    /// Aggregate declared-RAM ceiling for all plugins together.
    func declaredBudgetGB(_ status: MemoryStatus) -> Double {
        declaredBudgetGB(status, fraction: residentFraction)
    }

    private func declaredBudgetGB(_ status: MemoryStatus, fraction: Double) -> Double {
        max(0, status.physicalGB * fraction)
    }

    /// Memory the arbiter is willing to commit to a newcomer right now.
    func liveHeadroomGB(_ status: MemoryStatus) -> Double {
        status.availableGB - safetyMarginGB
    }

    // MARK: Policy

    /// Decide whether `request` may become resident alongside `residents`.
    ///
    /// A plugin that is already resident is admitted without disturbing
    /// anything: re-entering a running server must not be able to evict it.
    func admit(_ request: PluginResidency, residents: [PluginResidency]) -> AdmissionDecision {
        if residents.contains(where: { $0.pluginID == request.pluginID }) {
            return .admit
        }
        return decide(request, residents: residents.filter { $0.pluginID != request.pluginID })
    }

    private func decide(_ request: PluginResidency, residents: [PluginResidency],
                        fraction: Double? = nil) -> AdmissionDecision {
        let status = probe()
        let budget = declaredBudgetGB(status, fraction: fraction ?? residentFraction)
        let headroom = liveHeadroomGB(status)

        var remaining = residents
        var evicted: [String] = []
        var freed: Double = 0

        while true {
            let residentDemand = remaining.reduce(0) { $0 + $1.declaredRamGB }
            let fitsBudget = residentDemand + request.declaredRamGB <= budget + Self.epsilon
            let fitsHeadroom = request.declaredRamGB <= headroom + freed + Self.epsilon
            if fitsBudget && fitsHeadroom { break }

            // Least recently used first; ties broken by identifier so the plan is
            // reproducible for a given input rather than dependent on dictionary
            // ordering.
            let candidates = remaining.filter(\.isEvictable)
                .sorted { ($0.lastUsed, $0.pluginID) < ($1.lastUsed, $1.pluginID) }
            guard let victim = candidates.first else {
                let stillResident = remaining.reduce(0) { $0 + $1.declaredRamGB }
                let available = max(0, min(budget - stillResident, headroom + freed))
                // Only the live reading stands in the way: the user may
                // overrule it. Evictions are the ones the budget needs, not
                // the ones made chasing headroom that was never going to come.
                if fitsBudget {
                    return .refuseLiveHeadroom(
                        requiredGB: request.declaredRamGB, availableGB: available,
                        evictions: budgetEvictions(request, residents: residents, budget: budget))
                }
                return .refuse(requiredGB: request.declaredRamGB, availableGB: available)
            }

            remaining.removeAll { $0.pluginID == victim.pluginID }
            evicted.append(victim.pluginID)
            freed += victim.declaredRamGB
        }

        return evicted.isEmpty ? .admit : .evictThenAdmit(evicted)
    }

    /// The least-recently-used evictions that make `request` fit `budget`,
    /// ignoring live headroom. Only called once the budget is known to fit.
    private func budgetEvictions(_ request: PluginResidency, residents: [PluginResidency],
                                 budget: Double) -> [String] {
        var demand = residents.reduce(0) { $0 + $1.declaredRamGB }
        var evicted: [String] = []
        let candidates = residents.filter(\.isEvictable)
            .sorted { ($0.lastUsed, $0.pluginID) < ($1.lastUsed, $1.pluginID) }
        for victim in candidates where demand + request.declaredRamGB > budget + Self.epsilon {
            demand -= victim.declaredRamGB
            evicted.append(victim.pluginID)
        }
        return evicted
    }

    /// Admission for a one-shot invocation.
    ///
    /// Identical accounting to `admit`, with one difference that matters: a
    /// one-shot process is transient and owns no resident slot, so a server
    /// already running under the same identifier is not a reason to skip the
    /// check. The subprocess needs its own peak on top of whatever is held, and
    /// that sibling is as evictable as any other.
    ///
    /// A job whose declaration exceeds the shared budget on its own is then
    /// re-decided against `oneShotFraction`; see there.
    ///
    /// The caller passes the residents *other than* this invocation: a one-shot
    /// already in flight for the same plugin belongs in the set, the request
    /// itself does not (see `PluginRuntime.oneShotAdmissionResidents`).
    func admitOneShot(_ request: PluginResidency, residents: [PluginResidency]) -> AdmissionDecision {
        let shared = decide(request, residents: residents)
        guard case .refuse = shared,
              oneShotFraction > residentFraction,
              request.declaredRamGB > declaredBudgetGB(probe()) + Self.epsilon
        else { return shared }
        return decide(request, residents: residents, fraction: oneShotFraction)
    }

    /// Plugins to stop before `request` runs, without deciding admission — used
    /// by callers that want to pre-empt proactively.
    func evictionPlan(for request: PluginResidency, residents: [PluginResidency]) -> [String] {
        admit(request, residents: residents).evictions
    }

    /// Tolerance for the comparisons above. Declared figures are one-decimal
    /// gigabyte values from JSON; without a tolerance a sum such as 5.0 + 3.0
    /// can fail a `<= 8.0` test on binary floating point.
    private static let epsilon = 1e-9
}

// MARK: - Session admission

/// LRU bookkeeping for `session` plugins, which bound their own cache but rely
/// on the host to decide which entry to drop (PLUGIN_PROTOCOL.md section 1.2).
struct SessionLedger: Sendable {
    private(set) var order: [String] = []
    let limit: Int

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    /// Record use of a session, returning the sessions that must be closed to
    /// stay within `limit`.
    mutating func touch(_ sessionID: String) -> [String] {
        order.removeAll { $0 == sessionID }
        order.append(sessionID)
        var evicted: [String] = []
        while order.count > limit {
            evicted.append(order.removeFirst())
        }
        return evicted
    }

    mutating func remove(_ sessionID: String) {
        order.removeAll { $0 == sessionID }
    }

    mutating func removeAll() {
        order.removeAll()
    }
}
