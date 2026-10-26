// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import CoreMIDI
import Foundation
import RaveAudio

/// CoreMIDI input from every source (hot-plug aware), MIDI learn, mapped actions and MIDI clock in.
/// Parsing, the clock estimator and the mapping format live in RaveAudio/MidiCore.swift (unit-tested).
final class MidiControl {
    /// Things a controller can drive. Raw values are the names stored in the mapping JSON.
    enum Action: String, CaseIterable {
        case modeNext, modePrev, presetNext, presetPrev, intensity, brightness, strobe, blackout,
             tapTempo, nudgeEarlier, nudgeLater, bpmUp, bpmDown, autoCycle
        var title: String {
            switch self {
            case .modeNext: return "Mode next"
            case .modePrev: return "Mode previous"
            case .presetNext: return "Preset next"
            case .presetPrev: return "Preset previous"
            case .intensity: return "Intensity (knob: Chill/Normal/Wild, pad: cycle)"
            case .brightness: return "Master brightness (knob)"
            case .strobe: return "Strobe (hold; 3 flashes/s limit applies)"
            case .blackout: return "Blackout (toggle)"
            case .tapTempo: return "Tap tempo"
            case .nudgeEarlier: return "Beat nudge earlier (-10 ms)"
            case .nudgeLater: return "Beat nudge later (+10 ms)"
            case .bpmUp: return "BPM +0.1"
            case .bpmDown: return "BPM -0.1"
            case .autoCycle: return "Auto-cycle on/off"
            }
        }
    }

    private(set) var mappings = MidiMappingSet()
    let mappingURL: URL
    /// Called on the main thread for every mapped control.
    var onAction: ((Action, MidiTrigger) -> Void)?
    /// Called on the main thread with every control that moves (MIDI learn shows it).
    var onControl: ((MidiControlID, MidiEvent) -> Void)?
    var log: ((String) -> Void)?
    /// When set, the next control that moves is bound to this action.
    var learnTarget: Action?
    private(set) var lastControl: MidiControlID?
    private(set) var sourceNames: [String] = []
    private(set) var eventCount = 0

    let clock = MidiClockEstimator()
    private let clockLock = NSLock()
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var connected = Set<MIDIEndpointRef>()
    private let triggers = MidiTriggerState()
    private var timebase: Double = {
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom) / 1e9
    }()
    private(set) var started = false

    init(mappingURL: URL) {
        self.mappingURL = mappingURL
        if let d = try? Data(contentsOf: mappingURL), let m = try? MidiMappingSet.decode(d) { mappings = m }
    }

    var clockSync: Bool {
        get { mappings.clockSync }
        set { mappings.clockSync = newValue; save() }
    }

    func start() {
        guard !started else { return }
        var st = MIDIClientCreateWithBlock("RAVE LIVE" as CFString, &client) { [weak self] note in
            if note.pointee.messageID == .msgSetupChanged { DispatchQueue.main.async { self?.connectSources() } }
        }
        guard st == noErr else { log?("midi: client failed (\(st))"); return }
        st = MIDIInputPortCreateWithProtocol(client, "RAVE LIVE In" as CFString, ._1_0, &port) { [weak self] list, _ in
            self?.receive(list)
        }
        guard st == noErr else { log?("midi: input port failed (\(st))"); return }
        started = true
        connectSources()
    }

    /// Connect every source that isn't connected yet (called at start and when devices come and go).
    func connectSources() {
        guard started else { return }
        var names: [String] = []
        var live = Set<MIDIEndpointRef>()
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            guard src != 0 else { continue }
            live.insert(src)
            var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(src, kMIDIPropertyDisplayName, &name)
            let n = (name?.takeRetainedValue() as String?) ?? "MIDI source \(i)"
            names.append(n)
            if !connected.contains(src) {
                if MIDIPortConnectSource(port, src, nil) == noErr { connected.insert(src); log?("midi: connected \(n)") }
            }
        }
        connected.formIntersection(live)
        sourceNames = names
    }

    private func receive(_ list: UnsafePointer<MIDIEventList>) {
        let n = Int(list.pointee.numPackets)
        guard n > 0 else { return }
        var p = UnsafeMutablePointer(mutating: UnsafeRawPointer(list).advanced(by: MemoryLayout<MIDIEventList>.offset(of: \MIDIEventList.packet)!)
            .assumingMemoryBound(to: MIDIEventPacket.self))
        for _ in 0..<n {
            let ts = p.pointee.timeStamp
            let t = Double(ts == 0 ? mach_absolute_time() : ts) * timebase
            let words = UnsafeRawPointer(p).advanced(by: MemoryLayout<MIDIEventPacket>.offset(of: \MIDIEventPacket.words)!).assumingMemoryBound(to: UInt32.self)
            let wc = Int(p.pointee.wordCount)
            var i = 0
            while i < wc {
                let w = words[i]
                let mt = w >> 28
                if let e = MidiEvent.parse(umpWord: w) { handle(e, at: t) }
                // UMP sizes: types 0-2 are 1 word, 3-4 are 2, 5 is 4 (only 1/2 carry MIDI 1.0 messages we use)
                i += mt <= 2 ? 1 : (mt <= 4 ? 2 : 4)
            }
            p = MIDIEventPacketNext(p)
        }
    }

    private func handle(_ e: MidiEvent, at t: Double) {
        switch e {
        case .clockTick:
            clockLock.lock(); clock.tick(at: t); clockLock.unlock()
            return
        case .start, .stop:
            clockLock.lock(); clock.reset(); clockLock.unlock()
            return
        case .resume: return
        default: break
        }
        guard let c = e.control else { return }
        DispatchQueue.main.async { [weak self] in self?.dispatch(e, control: c) }
    }

    private func dispatch(_ e: MidiEvent, control c: MidiControlID) {
        eventCount += 1
        lastControl = c
        onControl?(c, e)
        if let target = learnTarget {
            if case .noteOff = e { return }                 // learn on the press, not the release
            learnTarget = nil
            bindNow(c, to: target)
            _ = triggers.trigger(for: e)                     // prime edge state, don't fire on the learning move
            return
        }
        guard let name = mappings.action(for: c), let a = Action(rawValue: name), let tr = triggers.trigger(for: e) else { return }
        onAction?(a, tr)
    }

    /// Current MIDI clock tempo if a clock is running.
    func clockBPM() -> Double? {
        let t = Double(mach_absolute_time()) * timebase
        clockLock.lock(); defer { clockLock.unlock() }
        return clock.isPresent(now: t) ? clock.bpm : nil
    }

    func bindNow(_ c: MidiControlID, to a: Action) {
        mappings.bind(c, to: a.rawValue)
        save()
        log?("midi: learned \(c) -> \(a.rawValue)")
    }
    func unbind(_ a: Action) { mappings.unbind(action: a.rawValue); save() }
    func clearAll() { let cs = mappings.clockSync; mappings = MidiMappingSet(); mappings.clockSync = cs; save() }

    func save() {
        do {
            try FileManager.default.createDirectory(at: mappingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try mappings.encoded().write(to: mappingURL, options: .atomic)
        } catch { log?("midi: could not save mappings: \(error.localizedDescription)") }
    }
    func importMappings(from url: URL) throws {
        mappings = try MidiMappingSet.decode(Data(contentsOf: url))
        save()
        log?("midi: imported \(mappings.mappings.count) mappings from \(url.lastPathComponent)")
    }
    func exportMappings(to url: URL) throws { try mappings.encoded().write(to: url, options: .atomic) }

    static var defaultMappingURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSString(string: "~/Library/Application Support").expandingTildeInPath)
        return base.appendingPathComponent("RAVE LIVE/midi-mappings.json")
    }
}
