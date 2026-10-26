// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

import Foundation

/// MIDI pieces that don't need CoreMIDI (so they are unit-tested): Universal MIDI Packet parsing,
/// the 24 ppqn clock tempo estimator, and controller-to-action mappings (MIDI learn, JSON import/export).

public enum MidiEvent: Equatable {
    case cc(channel: Int, number: Int, value: Int)
    case noteOn(channel: Int, number: Int, velocity: Int)
    case noteOff(channel: Int, number: Int)
    case clockTick
    case start, stop, resume

    /// Parse one Universal MIDI Packet (CoreMIDI delivers MIDI 1.0 bytes as UMP type 1 = system, type 2 = channel voice).
    public static func parse(umpWord w: UInt32) -> MidiEvent? {
        let type = w >> 28
        let status = Int((w >> 16) & 0xFF)
        let d1 = Int((w >> 8) & 0x7F), d2 = Int(w & 0x7F)
        if type == 0x1 {
            switch status {
            case 0xF8: return .clockTick
            case 0xFA: return .start
            case 0xFB: return .resume
            case 0xFC: return .stop
            default: return nil
            }
        }
        guard type == 0x2 else { return nil }
        let ch = status & 0x0F
        switch status & 0xF0 {
        case 0xB0: return .cc(channel: ch, number: d1, value: d2)
        case 0x90: return d2 == 0 ? .noteOff(channel: ch, number: d1) : .noteOn(channel: ch, number: d1, velocity: d2)
        case 0x80: return .noteOff(channel: ch, number: d1)
        default: return nil
        }
    }

    /// The physical control this event came from (nil for clock / transport).
    public var control: MidiControlID? {
        switch self {
        case let .cc(c, n, _): return MidiControlID(kind: .cc, channel: c, number: n)
        case let .noteOn(c, n, _), let .noteOff(c, n): return MidiControlID(kind: .note, channel: c, number: n)
        default: return nil
        }
    }
}

/// Tempo from MIDI clock (24 pulses per quarter note): least-squares slope over the last 4 beats of ticks,
/// so per-tick jitter from USB / virtual ports averages out.
public final class MidiClockEstimator {
    public let window: Int
    private var times: [Double] = []
    public init(windowTicks: Int = 96) { window = max(8, windowTicks) }

    public func tick(at t: Double) {
        if let last = times.last, t - last > 0.5 || t <= last { times.removeAll() }   // gap or clock restart
        times.append(t)
        if times.count > window + 1 { times.removeFirst(times.count - window - 1) }
    }
    public func reset() { times.removeAll() }
    public var lastTick: Double? { times.last }

    /// BPM once a full beat of ticks has arrived, else nil.
    public var bpm: Double? {
        let n = times.count
        guard n >= 25 else { return nil }
        var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
        let t0 = times[0]
        for i in 0..<n {
            let x = Double(i), y = times[i] - t0
            sx += x; sy += y; sxx += x * x; sxy += x * y
        }
        let dn = Double(n)
        let den = dn * sxx - sx * sx
        guard den > 0 else { return nil }
        let secPerTick = (dn * sxy - sx * sy) / den
        guard secPerTick > 0 else { return nil }
        let b = 60.0 / (secPerTick * 24.0)
        return b.isFinite && b >= 20 && b <= 400 ? b : nil
    }
    /// Clock counts as present while ticks keep coming.
    public func isPresent(now: Double) -> Bool { (times.last.map { now - $0 < 0.5 } ?? false) && bpm != nil }
}

public struct MidiControlID: Codable, Hashable, CustomStringConvertible {
    public enum Kind: String, Codable { case cc, note }
    public var kind: Kind
    public var channel: Int      // 0...15
    public var number: Int       // CC or note number
    public init(kind: Kind, channel: Int, number: Int) { self.kind = kind; self.channel = channel; self.number = number }
    public var description: String { "\(kind == .cc ? "CC" : "Note") \(number) ch\(channel + 1)" }
}

public struct MidiMapping: Codable, Equatable {
    public var control: MidiControlID
    public var action: String
    public init(control: MidiControlID, action: String) { self.control = control; self.action = action }
}

/// The mapping file (Application Support/RAVE LIVE/midi-mappings.json, also the import/export format).
public struct MidiMappingSet: Codable, Equatable {
    public var version = 1
    public var mappings: [MidiMapping] = []
    public var clockSync = true          // MIDI clock overrides the audio tempo tracker while it is running
    public init() {}

    /// Learn: one control drives one action, and one action listens to one control.
    public mutating func bind(_ c: MidiControlID, to action: String) {
        mappings.removeAll { $0.control == c || $0.action == action }
        mappings.append(MidiMapping(control: c, action: action))
    }
    public mutating func unbind(action: String) { mappings.removeAll { $0.action == action } }
    public func action(for c: MidiControlID) -> String? { mappings.first { $0.control == c }?.action }
    public func control(for action: String) -> MidiControlID? { mappings.first { $0.action == action }?.control }

    public func encoded() throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }
    public static func decode(_ d: Data) throws -> MidiMappingSet { try JSONDecoder().decode(MidiMappingSet.self, from: d) }
}

/// Turns raw events for a mapped control into what an action should do: CC knobs give a continuous value,
/// CC buttons/pads fire on the rising edge through 64, notes fire on note-on and report release for hold actions.
public struct MidiTrigger: Equatable {
    public var value: Float          // 0...1 (CC value / 127, note velocity / 127, 0 on release)
    public var pressed: Bool         // rising edge (note-on, CC crossing up through 64)
    public var released: Bool        // note-off, CC crossing down through 64
    public var continuous: Bool      // came from a CC (knob/fader) rather than a note
}

public final class MidiTriggerState {
    private var last: [MidiControlID: Int] = [:]
    public init() {}
    public func trigger(for e: MidiEvent) -> MidiTrigger? {
        switch e {
        case let .cc(c, n, v):
            let id = MidiControlID(kind: .cc, channel: c, number: n)
            let prev = last[id] ?? 0
            last[id] = v
            return MidiTrigger(value: Float(v) / 127, pressed: v >= 64 && prev < 64, released: v < 64 && prev >= 64, continuous: true)
        case let .noteOn(_, _, vel): return MidiTrigger(value: Float(vel) / 127, pressed: true, released: false, continuous: false)
        case .noteOff: return MidiTrigger(value: 0, pressed: false, released: true, continuous: false)
        default: return nil
        }
    }
}
