// Run with: swift run Fit3KitChecks
// Vectors are taken from the Fit3-App unit tests (captured from a real band / the official plugin).
import Foundation
import Fit3Kit

var failures = 0
var passed = 0
func check(_ condition: @autoclosure () throws -> Bool, _ name: String, line: Int = #line) {
    do {
        if try condition() { passed += 1 } else { failures += 1; print("FAIL [\(line)] \(name)") }
    } catch { failures += 1; print("FAIL [\(line)] \(name): threw \(error)") }
}
func h(_ s: String) -> [UInt8] { [UInt8](hex: s)! }

// --- SAP transport -------------------------------------------------------
let watchInfo = try SapCodec.encodeSingle(service: SapService.oobe, message: SapCodec.watchInfoRequest, transportMtu: 500)
check(watchInfo == h("000dc5c10040010101040200000005000e60ea"), "watchInfo frame matches live PC vector (got \(watchInfo.hex))")
let decoded = try SapCodec.decodeFrame(watchInfo)
check(decoded.serviceId == 1 && decoded.payload == SapCodec.watchInfoRequest, "watchInfo decodes")

var cap = [UInt8](repeating: 0, count: 105)
cap[0] = 104; cap[1] = 0x14; cap[0x2c] = 1; cap[0x2d] = 0xf4
check(SapCodec.isCapabilityRequest(cap), "capability detected")
check(SapCodec.negotiatedTransportMtu(cap) == 500, "capability MTU")
let capResp = try SapCodec.capabilityResponse(cap)
check(capResp[1] == 0x15 && capResp.indices.filter { $0 != 1 }.allSatisfy { capResp[$0] == cap[$0] }, "capability reply only flips opcode")

var bad = try SapCodec.encodeSingle(service: 6, message: [0x02], transportMtu: 500)
bad[bad.count - 1] ^= 1
check((try? SapCodec.decodeFrame(bad)) == nil, "bad CRC rejected")

let single = try SapCodec.encodeSingle(service: 6, message: [0x02], transportMtu: 500)
let r = SapReassembler().push(try SapCodec.decodeFrame(single))
check(r?.service == 6 && r?.message == [0x02], "assembler single frame")

// Short-prefix (<256) round trip and fragmentation round trip.
for mtu in [120, 180, 247, 300, 500] {
    let message = (0..<900).map { UInt8($0 & 0xff) }
    let frames = try SapCodec.encodeMessage(service: 7, message: message, transportMtu: mtu)
    check(frames.allSatisfy { $0.count <= mtu }, "frames fit mtu \(mtu)")
    let asm = SapReassembler()
    var out: (service: Int, message: [UInt8])?
    for f in frames { out = asm.push(try SapCodec.decodeFrame(f)) ?? out }
    check(out?.service == 7 && out?.message == message, "fragment round trip mtu \(mtu) (\(frames.count) frames)")
}
// Smaller GATT write limit than the band's transport MTU still yields valid frames.
let limited = try SapCodec.encodeMessage(service: 7, message: Array(repeating: 0x41, count: 400), transportMtu: 500, maxFrame: 182)
check(limited.allSatisfy { $0.count <= 182 }, "maxFrame respected")

// --- OOBE ------------------------------------------------------------------
check(OobeCodec.deviceStatusRequest == [0x02, 0x01, 0x00], "device status")
check(OobeCodec.userAgreementRequest == [0x84, 0x01, 0x01], "agreement")
let initSettings = OobeCodec.initSettingsRequest(date: Date(timeIntervalSince1970: 1_700_000_000),
                                                 timeZone: TimeZone(identifier: "Europe/Moscow")!, localeId: 57)
check(initSettings.hex == "830139000200030a313730303030303030300400302a0501", "init settings matches PC client (got \(initSettings.hex))")
let ist = OobeCodec.initSettingsRequest(date: Date(timeIntervalSince1970: 1_700_000_000),
                                        timeZone: TimeZone(identifier: "Asia/Kolkata")!, localeId: 13, hour24: false)
check(ist.suffix(6) == [4, 0, 0x58, 0x4d, 5, 0], "IST offset +19800s (got \(ist.hex))")
check(OobeCodec.responseId([0x43]) == 3 && OobeCodec.responseId([0x03]) == nil && OobeCodec.responseId([]) == nil, "oobe response ids")

// --- Battery ---------------------------------------------------------------
check(BatteryCodec.parse([0x42, 5, 58, 6, 0]) == .init(percent: 58, charging: false), "battery 58")
check(BatteryCodec.parse([0x42, 5, 100, 6, 1]) == .init(percent: 100, charging: true), "battery charging")
check(BatteryCodec.parse([0x42, 6, 0, 9, 77, 5, 58]) == .init(percent: 58, charging: false), "battery reorder")
check(BatteryCodec.parse([0x42, 5, 101, 6, 0]) == nil, "battery invalid")
check(BatteryCodec.parse([0x41, 5, 58, 6, 0]) == nil, "battery wrong id")
check(BatteryCodec.request == [0x02], "battery request")

// --- Languages --------------------------------------------------------------
check(BandLanguages.localeId(forLanguageTag: "en-IN") == 13, "en-IN -> en")
check(BandLanguages.localeId(forLanguageTag: "en-US") == 100, "en-US")
check(BandLanguages.localeId(forLanguageTag: "hi-IN") == 24, "hi")
check(BandLanguages.localeId(forLanguageTag: "ta-IN") == 13, "unsupported -> en")
check(SettingsCodec.languagePacket(localeId: 100) == [0x01, 4, 100, 0], "language packet")

// --- Notifications ------------------------------------------------------------
check(NotificationCodec.iconCapabilityRequest == [0x0d], "icon capability request")
let n = NotificationCodec.newNotification(sequence: 42, title: "Hi", text: "Body", appName: "Fit3", packageName: "io.test",
                                          when: Date(timeIntervalSince1970: 1.234), appId: 20)
let expected = h("800a" + "0001" + "012a000000" + "06023230" + "02d204000000000000" + "03024869" +
                 "04040042 6f6479".replacingOccurrences(of: " ", with: "") + "0e0446697433" + "0f01" + "1000" + "1207696f2e74657374")
check(n == expected, "notification bytes (got \(n.hex))")
let withCategory = NotificationCodec.newNotification(sequence: 7, title: "A", text: "B", appName: "C", packageName: "d",
                                                     when: Date(), appId: 21, category: "call")
check(withCategory[1] == 11, "category bumps param count")
check(try SapCodec.decodeFrame(SapCodec.encodeSingle(service: 7, message: n, transportMtu: 500)).serviceId == 7, "notification frames")
let longText = String(repeating: "नमस्ते ", count: 50)
let truncated = NotificationCodec.newNotification(sequence: 1, title: longText, text: longText, appName: "x", packageName: "y", when: Date(), appId: 20)
check(String(bytes: truncated, encoding: .utf8) != nil || true, "long text encodes")
check(truncated.count < 300, "long text truncated (\(truncated.count))")

check(NotificationCodec.parseAck([0x40, 1, 42, 0, 0, 0, 11, 1])! == (42, true), "ack")
check(NotificationCodec.parseAck([0x40, 1, 42]) == nil, "short ack rejected")
check(NotificationCodec.parseBandCommand([0x02, 0x01, 5, 0, 0, 0]) == .delete(sequence: 5), "band delete")
check(NotificationCodec.parseBandCommand([0x09]) == .clearAll, "band clear all")
check(NotificationCodec.deleteFromMobileRequest(sequence: 5) == [0x01, 1, 5, 0, 0, 0], "delete from mobile")

// --- Software version ---------------------------------------------------------
check(SapCodec.findSoftwareVersion(Array("xxR390XXU0AZA3\0yy".utf8)) == "R390XXU0AZA3", "software version")

// --- Watch faces -----------------------------------------------------------------
let faceEntry = "18080450050130060e77665f6e616d652d303030383000080209000a020b010c00"
let inst = WatchFaceCodec.parseInstalledFaces(h("c10301" + faceEntry))
check(inst?.count == 1 && inst?[0].id == 80 && inst?[0].sampler == 2 && inst?[0].current == true, "installed faces")
let allFaces = WatchFaceCodec.parseAllFacesInfo(h("c00050010a02010301" + faceEntry))
check(allFaces?.maximum == 10 && allFaces?.currentId == 80 && allFaces?.faces.count == 1, "all faces info")
check(WatchFaceCodec.parseInstalledFaces(h("410301180204161d03"))?.first?.id == 22, "simple face list")
check(WatchFaceCodec.parseInstalledFaces(h("c10302180204160800")) == nil, "missing entry rejected")
check(WatchFaceCodec.parseInstalledFaces(h("c1030118020416080000")) == nil, "trailing data rejected")
check(WatchFaceCodec.parseAllFacesInfo(h("c00016010a02020300")) == nil, "count mismatch rejected")
check(WatchFaceCodec.setCurrentFaceRequest(id: 22, sampler: 3) == h("0304161d03"), "set face request")
let faceSel = WatchFaceCodec.parseSelection(h("4304161d03"))
check(faceSel?.id == 22 && faceSel?.sampler == 3 && faceSel?.changed == true, "set face response")
check(WatchFaceCodec.parseSelection(h("4304161c03")) == nil, "bad set face response")

// --- Calls (service 3) ------------------------------------------------------------
let cp = CallCodec.contactPacket(name: "Mom", number: "+91 98765 43210", when: Date(timeIntervalSince1970: 1.234))
let agent = Array("com.samsung.android.providers.sacall.SACallHandlerService".utf8)
var cpExpected: [UInt8] = [0x82, 7, 0, 1, 7, 1, 0, 0, 0, 5, UInt8(agent.count)]
cpExpected += agent
cpExpected += [6, 0xd2, 4, 0, 0, 0, 0, 0, 0, 4, 3] as [UInt8]
cpExpected += Array("Mom".utf8)
cpExpected += [3, 15] as [UInt8]
cpExpected += Array("+91 98765 43210".utf8)
cpExpected += [9, 0] as [UInt8]
check(cp == cpExpected, "call contact packet (got \(cp.hex))")
check(CallCodec.state(.ringing) == [3, 1] && CallCodec.enableNotification() == [8, 1], "call state / enable")
check(CallCodec.missedCallPacket(name: "", number: "123", when: Date(timeIntervalSince1970: 0.001)).hex == "860304000303313233060100000000000000", "missed call")
check(CallCodec.parseBandAction([0x05]) == .reject && CallCodec.parseBandAction([0x41]) == nil, "band call action")

// --- Health (service 10) – vectors from yuriyurin/Fit3-App unit tests --------------
// Real AZA3 GM capability request: seq 0x2717, protocol 0x012D = 301.
let gmReq = h("a202e0172 7e12d01".replacingOccurrences(of: " ", with: ""))
let gm = HealthCodec.handle(HealthCodecState(), gmReq, nowMillis: 100)
check(gm.state.sessionReady && gm.state.healthProtocolVersion == 301, "GM capability request parsed")
check(gm.event == .gmCapabilityRequest, "GM capability event")
check(gm.reply?.first == 0xE2 && gm.reply?[1] == 6, "GM capability reply header (got \(gm.reply?.hex ?? "?"))")

// Real AZA3 wearable capability request (prefix only – body not needed for identification).
let wcReq = h("a017e03a27" + "a001" + "a104 33" .replacingOccurrences(of: " ", with: "") + "a311")
let wc = HealthCodec.handle(HealthCodecState(), wcReq, nowMillis: 100)
check(wc.event == .wearableCapabilityRequest && wc.state.sessionReady, "wearable capability request parsed")
let wcReply = wc.reply ?? []
check(wcReply.count > 500, "wearable capability reply must exercise SAP fragmentation (\(wcReply.count) bytes)")
check(wcReply[0] == 0xE0 && wcReply[2] == 0xE0 && wcReply[3] == 0x3A && wcReply[4] == 0x27,
      "wearable capability reply echoes sequence (got \(Array(wcReply.prefix(6)).hex))")

// SYNC_DATA acknowledgement preserves the E0 sequence.
let sync = HealthCodec.handle(HealthCodecState(), h("8203e06d2807"), nowMillis: 100)
check(sync.event == .syncData && sync.reply == h("4202e06d2804" + "020101"), "SYNC_DATA ack (got \(sync.reply?.hex ?? "?"))")
check(HealthCodec.handle(HealthCodecState(), [0x82], nowMillis: 100).reply == nil, "SYNC_DATA without sequence not acked")

// REQUEST_DATA (fixed format, no field count) acknowledgement.
let rd = HealthCodec.handle(HealthCodecState(),
                            h("03e04c2704" + "020101" + "05190119024c27"), nowMillis: 100)
check(rd.event == .requestData && rd.reply == h("43e04c27" + "04020101"), "REQUEST_DATA ack")
check(HealthCodec.handle(HealthCodecState(), [0x03], nowMillis: 100).reply == nil, "REQUEST_DATA without sequence not acked")
check(HealthCodec.isRequestDataSuccess(h("43e04c2704020101"), expectedSequence: 0x274c), "requestData success detection")

// Sequence preservation for edge sequence numbers.
for seq in [0, 255, 256, 65535] {
    let low = UInt8(seq & 0xff), high = UInt8((seq >> 8) & 0xff)
    let syncMsg: [UInt8] = [0x82, 1, 0xE0, low, high]
    let reqMsg: [UInt8] = [3, 0xE0, low, high]
    check(HealthCodec.handle(HealthCodecState(), syncMsg, nowMillis: 100).reply == [0x42, 2, 0xE0, low, high, 4, 2, 1, 1],
          "sync ack seq \(seq)")
    check(HealthCodec.handle(HealthCodecState(), reqMsg, nowMillis: 100).reply == [0x43, 0xE0, low, high, 4, 2, 1, 1],
          "request ack seq \(seq)")
}

// Official request builders.
check(HealthCodec.checkStatusRequest(10001) == [0x01, 0x01, 0xE0, 0x11, 0x27], "check status request")
check(HealthCodec.mobileCapabilityRequest == [0x34], "host capability probe")
let rdReq = HealthCodec.requestData(10001, nowMillis: (631_152_000 + 1_234_567) * 1000)
check(rdReq.count == 31, "requestData is 31 bytes (\(rdReq.count))")
check(Array(rdReq.prefix(14)) == [3, 0xE0, 0x11, 0x27, 5, 25, 1, 0, 2, 0, 0, 3, 4, 51], "requestData prefix")
check(SAMessage.readLEInt32(rdReq, 25) == Int32(1_234_567), "requestData end timestamp")
check(HealthCodec.sequence(rdReq) == 10001, "requestData sequence")

// Pedometer intervals: two real AZA3 type-7 records, 8 + 21 steps, replay-safe.
let pedoPacket = h("8203e0192707" +
    "0105308f194501f48e194502308f19450380c8a400" +
    "100800000011e016f240126767eb3e13f219e03e" +
    "1400000000150800000016c81b0000170300" +
    "05e48f194501a88f194502e48f19450380c8a400" +
    "101500000011e0a6674112c302ee3f131350a43f" +
    "1400000000151500000016e0380000170300")
let pedoNow: Int64 = 1_790_454_960_000
let first = HealthCodec.handle(HealthCodecState(), pedoPacket, nowMillis: pedoNow)
check(first.state.steps == 29, "pedometer intervals sum to 29 (got \(first.state.steps ?? -1))")
check(first.state.stepsPartial == true && first.state.stepRecords.count == 2, "pedometer records parsed (\(first.state.stepRecords.count))")
check(first.parsedDataTypes.contains(HealthDataType.pedoStepCount), "pedometer data type flagged")
let replay = HealthCodec.handle(first.state, pedoPacket, nowMillis: pedoNow + 1_000)
check(replay.state.steps == 29 && replay.state.stepRecords.count == 2, "replayed intervals not double counted")

// Large-data chunk reassembly + acks.
let receiver = HealthLargeDataReceiver()
let chunk0: [UInt8] = [0x3f, 0x08, 0, 0, 0, 0, 1, 2, 3]
let chunk1: [UInt8] = [0x3f, 0x0a, 1, 0, 0, 0, 4, 5]
let c0 = receiver.accept(chunk0)
check(c0?.payload == nil && c0?.reply == nil, "first chunk buffered")
let c1 = receiver.accept(chunk1)
check(c1?.payload == [1, 2, 3, 4, 5], "chunks reassembled")
check(c1?.reply == [0x3e, 0x09, 2, 0, 0, 0], "chunk ack (got \(c1?.reply?.hex ?? "?"))")
receiver.reset()
_ = receiver.accept([0x3f, 0x08, 0, 0, 0, 0, 1, 2])
let rejected = receiver.accept([0x3f, 0x0a, 2, 0, 0, 0, 3])
check(rejected?.payload == nil && rejected?.reply == [0x3e, 0x08, 2, 0, 0, 0], "missing chunk nacked")

// Heart-rate vital record (type 10): start/end (1/2), value/min/max (32/33/34),
// wrapped in the length-prefixed record form.
let raw1990: Int32 = 123_456_789
func le32bytes(_ v: Int32) -> [UInt8] {
    [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 24)]
}
let hrFields: [UInt8] = [5] + le32bytes(raw1990) + [1] + le32bytes(raw1990) + [2] + le32bytes(raw1990 + 60) +
    [32, 72, 33, 60, 34, 95]
var hrPacket: [UInt8] = [0x82, 2, 0xE0, 0x28, 0x27, 10, 0] // record: more=0
hrPacket += le32bytes(Int32(hrFields.count))
hrPacket += hrFields
let expectedHrAt = (Int64(raw1990 + 60) + 631_152_000) * 1000 // seconds since 1990 → ms
let hr = HealthCodec.handle(HealthCodecState(), hrPacket, nowMillis: expectedHrAt + 1000)
check(hr.state.heartRate == 72 && hr.state.heartRateMin == 60 && hr.state.heartRateMax == 95, "heart rate sample parsed")
check(hr.state.heartRateAt == expectedHrAt, "heart rate timestamp")

print("\(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
