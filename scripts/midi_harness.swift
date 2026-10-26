// Copyright (c) 2026 Jed Brown
// SPDX-License-Identifier: GPL-3.0-only
// Part of RAVE LIVE: https://github.com/jedbrnth-eng/rave-live

// Test harness: a virtual MIDI controller ("RAVE Harness") that a running RAVE LIVE picks up like any USB controller.
// Sends a learn move (CC 7), an intensity knob (CC 1), preset pads (note 36), a strobe pad (note 38), then MIDI clock
// at 128 BPM, 100 BPM, and silence, so the app's log shows each mapping firing and the clock tempo it reads.
// Run: swiftc -O scripts/midi_harness.swift -o build/midi_harness && build/midi_harness [--scheduled]
// Clock ticks go out from a real-time (time-constraint) thread like a hardware/DAW clock. By default each tick is
// stamped with the moment it actually left (worst case on a busy Mac); --scheduled stamps the intended tick time,
// which is what DAWs that schedule MIDI clock ahead do.
import CoreMIDI
import Foundation

var client = MIDIClientRef(), src = MIDIEndpointRef()
guard MIDIClientCreateWithBlock("RAVE Harness" as CFString, &client, nil) == noErr,
      MIDISourceCreateWithProtocol(client, "RAVE Harness" as CFString, ._1_0, &src) == noErr else { print("FAIL: could not create virtual source"); exit(1) }
var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
func ticks(_ s: Double) -> UInt64 { UInt64(s * 1e9 * Double(tb.denom) / Double(tb.numer)) }
let t0 = mach_absolute_time()
func now() -> Double { Double(mach_absolute_time() - t0) * Double(tb.numer) / Double(tb.denom) / 1e9 }
func log(_ s: String) { print(String(format: "%7.3f  %@", now(), s)); fflush(stdout) }

let scheduled = CommandLine.arguments.contains("--scheduled")

func send(_ word: UInt32, at stamp: UInt64 = 0) {
    var list = MIDIEventList()
    let pkt = MIDIEventListInit(&list, ._1_0)
    var w = word
    _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, pkt, stamp == 0 ? mach_absolute_time() : stamp, 1, &w)
    MIDIReceivedEventList(src, &list)
}
func cc(_ n: UInt32, _ v: UInt32, ch: UInt32 = 0) { send(0x2000_0000 | (0xB0 | ch) << 16 | n << 8 | v); log("CC \(n) = \(v) ch\(ch + 1)") }
func noteOn(_ n: UInt32, _ v: UInt32 = 100) { send(0x2090_0000 | n << 8 | v); log("note on \(n) vel \(v)") }
func noteOff(_ n: UInt32) { send(0x2080_0000 | n << 8); log("note off \(n)") }
func pause(_ s: Double) { mach_wait_until(mach_absolute_time() + ticks(s)) }
func clock(bpm: Double, seconds: Double) {
    log(String(format: "clock start %.1f BPM for %.0f s (%@ timestamps)", bpm, seconds, scheduled ? "scheduled" : "send-time"))
    let period = 60.0 / (bpm * 24)
    let start = mach_absolute_time()
    var i = 0.0
    var late: [Double] = []       // how late each tick left (scheduler wake-up), stamped into the message as-is
    while i * period < seconds {
        let target = start + ticks(i * period)
        mach_wait_until(target)
        late.append(Double(mach_absolute_time() - target) * Double(tb.numer) / Double(tb.denom) / 1e6)
        send(0x10F8_0000, at: scheduled ? target : 0)
        i += 1
    }
    late.sort()
    log(String(format: "clock: sent %d ticks; send lateness p50 %.2f ms, p95 %.2f ms, max %.2f ms", Int(i), late[late.count / 2], late[late.count * 95 / 100], late.last ?? 0))
}

// real-time scheduling for the sender thread: 1 ms of work every ~20 ms tick
var policy = thread_time_constraint_policy_data_t(period: UInt32(ticks(0.0195)), computation: UInt32(ticks(0.001)),
                                                   constraint: UInt32(ticks(0.005)), preemptible: 1)
let policyCount = MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size
let rt = withUnsafeMutablePointer(to: &policy) {
    $0.withMemoryRebound(to: integer_t.self, capacity: policyCount) {
        thread_policy_set(pthread_mach_thread_np(pthread_self()), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0,
                          mach_msg_type_number_t(policyCount))
    }
}
log("virtual source up (real-time thread: \(rt == KERN_SUCCESS ? "yes" : "no, \(rt)")); waiting for the app to connect")
pause(2.0)
cc(7, 100)                 // learn move (app armed with --midi-learn brightness)
pause(0.5)
cc(7, 40); pause(0.4)      // brightness ~31 %
cc(7, 127); pause(0.4)
for v: UInt32 in [0, 64, 127] { cc(1, v); pause(0.5) }    // intensity Chill / Normal / Wild
for _ in 0..<3 { noteOn(36); pause(0.1); noteOff(36); pause(0.4) }   // preset next x3
noteOn(38); pause(1.2); noteOff(38)                                   // strobe hold
pause(0.5)
clock(bpm: 128, seconds: 8)
clock(bpm: 100, seconds: 6)
log("clock stopped"); pause(3)
log("done")
MIDIEndpointDispose(src)
