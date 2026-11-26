import AppKit
import ApplicationServices
import Foundation

struct ActiveEventTarget {
    let pid: Int32
    let name: String?
    let bundleIdentifier: String?
    let evidence: String
}

struct ActiveSample {
    let startObserved: Bool
    let tailIntercepted: Bool
    let tailChanged: Bool
    let targets: [ActiveEventTarget]
}

private struct MonitorFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

private let observedFlags: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
private let controlCode: CGKeyCode = 90 // F20. Calibration uses only releases, never a key press.

private extension KeyCombo {
    var eventFlags: CGEventFlags {
        var flags = CGEventFlags()
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        return flags
    }
}

private enum Stage { case start, sink, verifier }
private enum ProbeKind { case positiveControl, negativeControl, shortcut }
private struct SystemNotification {
    let tag: Int64
    let time: CGEventTimestamp
    let pid: Int32
}

// Every mutable field in a Pulse is protected by the worker's condition.
private final class Pulse {
    let kind: ProbeKind
    let code: CGKeyCode
    let flags: CGEventFlags
    let downTag: Int64
    var upTag: Int64 { downTag + 1 }
    var startTime: CGEventTimestamp?
    var upTime: CGEventTimestamp?
    var sinkSeen = false
    var changed = false
    var verifierSeen = false
    var notifications = [SystemNotification]()

    init(_ kind: ProbeKind, code: CGKeyCode, flags: CGEventFlags, tag: Int64) {
        self.kind = kind
        self.code = code
        self.flags = flags
        self.downTag = tag
    }

    var controlObserved: Bool {
        startTime != nil && sinkSeen && (kind == .negativeControl || verifierSeen)
    }
}

private final class TapWorker {
    let condition = NSCondition()
    let prefix = Int64.random(in: 1...Int64(Int32.max)) << 32
    var active: Pulse?
    var failure: MonitorFailure?
    var stopping = false
    var ready = false
    var armed = false
    var lastInputUptime = ProcessInfo.processInfo.systemUptime
    var ports = [CFMachPort]()

    // Called with the condition held. Never retry injections after a tap has failed.
    func fail(_ message: String) {
        if failure == nil { failure = MonitorFailure(message) }
        condition.broadcast()
    }

    func receive(_ stage: Stage, _ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let passthrough = Unmanaged.passUnretained(event)
        condition.lock()
        defer { condition.unlock() }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            fail("系统停用了事件监听，已中止主动扫描。")
            return passthrough
        }
        let tag = event.getIntegerValueField(.eventSourceUserData)
        if type.rawValue == 14 {
            if stage == .sink, let p = active, p.kind == .shortcut,
               let nsEvent = NSEvent(cgEvent: event), nsEvent.type == .systemDefined, nsEvent.subtype.rawValue == 6,
               let pid = Int32(exactly: event.getIntegerValueField(.eventTargetUnixProcessID)),
               pid > 0, pid != getpid() {
                // Buffer timestamps only within this single, bounded sample. Different
                // Mach ports on one run loop can deliver simultaneous observations in either order.
                if p.notifications.count < 128 {
                    p.notifications.append(SystemNotification(tag: tag, time: event.timestamp, pid: pid))
                } else { fail("系统热键事件过于密集，无法可靠关联。") }
            }
            return passthrough
        }
        guard type == .keyDown || type == .keyUp || type == .flagsChanged else { return passthrough }
        let own = (tag >> 32) == (prefix >> 32)
        guard own else {
            if armed && !stopping { fail("检测到其他键盘输入，已丢弃本次采样并停止。") }
            else if !armed {
                lastInputUptime = ProcessInfo.processInfo.systemUptime
                condition.broadcast()
            }
            // Some filters rewrite the tag. When the kernel still explicitly
            // identifies this CLI as the source, keep its event from the app.
            if armed && stage != .start && event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) {
                return nil
            }
            return passthrough
        }

        // Both tail taps always swallow our keyboard events, even late ones. Only
        // the named positive control is passed from the first tail tap to the second.
        guard let p = active, tag == p.downTag || tag == p.upTag else {
            if stage == .verifier { fail("后验监听器收到了迟到的标记事件，已停止。") }
            return stage == .start ? passthrough : nil
        }
        let expectedType: CGEventType = p.kind == .shortcut ? .keyDown : .keyUp
        if tag == p.downTag {
            let matches = type == expectedType && event.getIntegerValueField(.keyboardEventKeycode) == Int64(p.code)
                && event.flags.intersection(observedFlags) == p.flags
            switch stage {
            case .start:
                if matches && p.startTime == nil { p.startTime = event.timestamp }
                else { fail("起点收到了重复或不匹配的标记事件。") }
            case .sink:
                p.changed = p.changed || p.sinkSeen || !matches
                p.sinkSeen = true
            case .verifier:
                p.verifierSeen = true
            }
        } else if stage == .start {
            if type == .keyUp && p.upTime == nil && event.getIntegerValueField(.keyboardEventKeycode) == Int64(p.code) {
                p.upTime = event.timestamp
            } else {
                fail("标记释放事件在起点与请求不符。")
            }
        }
        condition.broadcast()
        if stage == .start { return passthrough }
        if tag == p.downTag && p.kind == .positiveControl && stage == .sink { return passthrough }
        if stage == .verifier && p.kind != .positiveControl {
            fail("标记按键越过末端拦截器，后验监听器已拦截，主动扫描已停止。")
        }
        return nil
    }

    func run() {
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let head = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                     options: .listenOnly, eventsOfInterest: mask, callback: { _, type, e, ptr in
            Unmanaged<TapWorker>.fromOpaque(ptr!).takeUnretainedValue().receive(.start, type, e)
        }, userInfo: context)
        let sink = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap, place: .tailAppendEventTap,
                                     options: .defaultTap, eventsOfInterest: mask | (CGEventMask(1) << 14),
                                     callback: { _, type, e, ptr in
            Unmanaged<TapWorker>.fromOpaque(ptr!).takeUnretainedValue().receive(.sink, type, e)
        }, userInfo: context)
        let verifier = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap, place: .tailAppendEventTap,
                                         options: .defaultTap, eventsOfInterest: mask, callback: { _, type, e, ptr in
            Unmanaged<TapWorker>.fromOpaque(ptr!).takeUnretainedValue().receive(.verifier, type, e)
        }, userInfo: context)
        let localPorts = [head, sink, verifier].compactMap { $0 }
        defer { for port in localPorts { CFMachPortInvalidate(port) } }
        let loop = CFRunLoopGetCurrent()
        let sources = localPorts.compactMap { CFMachPortCreateRunLoopSource(nil, $0, 0) }
        guard localPorts.count == 3, sources.count == 3 else {
            condition.lock()
            fail("无法安装起点、末端及后验监听器，未发送按键。")
            condition.unlock()
            return
        }
        for source in sources { CFRunLoopAddSource(loop, source, .defaultMode) }
        defer { for source in sources { CFRunLoopRemoveSource(loop, source, .defaultMode) } }
        for port in localPorts { CGEvent.tapEnable(tap: port, enable: true) }
        condition.lock()
        ports = localPorts
        ready = true
        condition.broadcast()
        condition.unlock()
        while true {
            condition.lock()
            let stop = stopping
            condition.unlock()
            if stop { break }
            autoreleasepool { _ = CFRunLoopRunInMode(.defaultMode, 0.05, false) }
        }
    }
}

final class ActiveEventMonitor {
    private let worker = TapWorker()
    private let ended = DispatchGroup()
    private let serial = NSLock()
    private let source: CGEventSource
    private var next: Int64 = 0

    private init(source: CGEventSource) { self.source = source }

    static func open() throws -> ActiveEventMonitor {
        let missing = [(AXIsProcessTrusted(), "辅助功能"), (CGPreflightListenEventAccess(), "输入监控"),
                       (CGPreflightPostEventAccess(), "发送键盘事件")].filter { !$0.0 }.map { $0.1 }
        guard missing.isEmpty else { throw MonitorFailure("缺少权限（" + missing.joined(separator: "、") + "），未发送按键。") }
        guard let source = CGEventSource(stateID: .privateState) else { throw MonitorFailure("无法创建独立事件源。") }
        source.localEventsSuppressionInterval = 0
        let monitor = ActiveEventMonitor(source: source)
        let worker = monitor.worker
        let ended = monitor.ended
        ended.enter()
        Thread.detachNewThread { defer { ended.leave() }; worker.run() }
        do {
            let limit = Date().addingTimeInterval(2)
            worker.condition.lock()
            while !worker.ready && worker.failure == nil && worker.condition.wait(until: limit) {}
            let failure = worker.failure
            let ready = worker.ready
            worker.condition.unlock()
            if let failure { throw failure }
            guard ready else { throw MonitorFailure("安装事件监听器超时。") }
            try monitor.armAfterQuietInterval()
            _ = try monitor.pulse(.positiveControl)
            _ = try monitor.pulse(.negativeControl)
            _ = try monitor.pulse(.positiveControl)
            return monitor
        } catch {
            monitor.stop()
            throw error
        }
    }

    deinit { stop() }

    // Terminal can still be delivering the Return that launched the command.
    // Count a brief quiet interval before arming. Only the last activity time
    // survives this interval; no ordinary key codes or characters are collected.
    private func armAfterQuietInterval() throws {
        let began = ProcessInfo.processInfo.systemUptime
        worker.condition.lock()
        defer { worker.condition.unlock() }
        while !worker.stopping {
            if let failure = worker.failure { throw failure }
            let now = ProcessInfo.processInfo.systemUptime
            if now - max(began, worker.lastInputUptime) >= 0.15,
               !CGEventSource.keyState(.hidSystemState, key: 36), !CGEventSource.keyState(.hidSystemState, key: 76),
               CGEventSource.flagsState(.hidSystemState).intersection(observedFlags.union(.maskSecondaryFn)).isEmpty {
                worker.armed = true
                return
            }
            if now - began >= 2 { break }
            _ = worker.condition.wait(until: Date().addingTimeInterval(0.04))
        }
        throw MonitorFailure("键盘未进入空闲状态，未发送按键。")
    }

    func stop() {
        worker.condition.lock()
        worker.stopping = true
        worker.condition.broadcast()
        worker.condition.unlock()
        _ = ended.wait(timeout: .now() + 1)
    }

    private func pulse(_ kind: ProbeKind, code: CGKeyCode = controlCode, flags: CGEventFlags = [],
                       milliseconds: Int = 700) throws -> Pulse {
        let p = Pulse(kind, code: code, flags: flags, tag: worker.prefix + next)
        next += 2
        let shortcut = kind == .shortcut
        guard let first = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: shortcut),
              let release = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
            throw MonitorFailure("无法构造完整的按下和释放事件，未发送按键。")
        }
        first.flags = flags
        first.setIntegerValueField(.eventSourceUserData, value: p.downTag)
        release.flags = flags
        release.setIntegerValueField(.eventSourceUserData, value: p.upTag)

        worker.condition.lock()
        defer { worker.active = nil; worker.condition.unlock() }
        if let failure = worker.failure { throw failure }
        guard !worker.stopping, worker.ports.allSatisfy({ CGEvent.tapIsEnabled(tap: $0) }) else {
            throw MonitorFailure("监听器已停止，未执行这项测试。")
        }
        guard CGEventSource.flagsState(.hidSystemState).intersection(observedFlags.union(.maskSecondaryFn)).isEmpty,
              !CGEventSource.keyState(.hidSystemState, key: code) else {
            throw MonitorFailure("键盘仍有修饰键或待测键按下，已停止。")
        }
        worker.active = p
        first.post(tap: .cgSessionEventTap)
        // No standalone modifier presses. Enqueue the matching release immediately,
        // before any sleep, cancellation point or application lookup.
        if shortcut { release.post(tap: .cgSessionEventTap) }
        let until = Date().addingTimeInterval(Double(milliseconds) / 1000)
        while !worker.stopping && worker.failure == nil && (shortcut || !p.controlObserved) {
            if !worker.condition.wait(until: until) { break }
        }
        if let failure = worker.failure { throw failure }
        guard !worker.stopping, worker.ports.allSatisfy({ CGEvent.tapIsEnabled(tap: $0) }) else {
            throw MonitorFailure("监听器在采样期间停止，结果已丢弃。")
        }
        guard p.startTime != nil, shortcut ? p.upTime != nil : p.controlObserved && !p.changed else {
            throw MonitorFailure(shortcut ? "起点未完整观察到标记按键，结果已丢弃。" : "末端拦截自检失败，未开始扫描。")
        }
        return p
    }

    func sample(_ combo: KeyCombo, milliseconds: Int = 180) throws -> ActiveSample {
        serial.lock()
        defer { serial.unlock() }
        guard (40...2000).contains(milliseconds), let code = CGKeyCode(exactly: combo.code),
              KeyCombo.keyNames[combo.code] != nil, !combo.modifiers.isEmpty,
              combo.modifiers.subtracting(.standardMask).isEmpty else { throw MonitorFailure("主动扫描组合或采样时长无效。") }
        do {
            let p = try pulse(.shortcut, code: code, flags: combo.eventFlags, milliseconds: milliseconds)
            // A positive tail barrier makes an otherwise silent tap failure observable
            // and separates subsequent samples from delayed marked keyboard events.
            _ = try pulse(.positiveControl)
            let targets = Self.attribution(p, milliseconds: milliseconds)
            return ActiveSample(startObserved: true, tailIntercepted: p.sinkSeen, tailChanged: p.changed, targets: targets)
        } catch {
            stop()
            throw error
        }
    }

    private static func attribution(_ p: Pulse, milliseconds: Int) -> [ActiveEventTarget] {
        guard let start = p.startTime else { return [] }
        let window = UInt64(milliseconds) * 1_000_000
        var scores = [Int32: Int]()
        for note in p.notifications {
            guard note.time >= start, note.time - start <= window, note.tag != p.upTag else { continue }
            if (note.tag >> 32) == (p.downTag >> 32) && note.tag != p.downTag { continue }
            let score: Int
            if note.tag == p.downTag { score = 3 }
            else if note.time == start && note.time != p.upTime { score = 2 }
            else if note.time != p.upTime { score = 1 }
            else { continue }
            scores[note.pid] = max(scores[note.pid] ?? 0, score)
        }
        let strongest = scores.values.max()
        return scores.keys.sorted().compactMap { pid in
            guard let score = scores[pid], score == strongest else { return nil }
            let app = NSRunningApplication(processIdentifier: pid)
            let evidence = score == 3 ? "marker" : score == 2 ? "same_timestamp" : "time_window"
            return ActiveEventTarget(pid: pid, name: app?.localizedName, bundleIdentifier: app?.bundleIdentifier,
                                     evidence: evidence)
        }
    }
}
