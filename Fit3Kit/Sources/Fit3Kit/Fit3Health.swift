// Fit3 Health transport (SAP service 10) – Swift port of Fit3HealthCodec.kt,
// Fit3VitalCodec.kt and Fit3PedometerBackSync.mergeRecords from
// yuriyurin/Fit3-App (GPL-3.0-only). Ported for Fit3BridgeFree.
//
// Important: tracker feature ids (sleep=12, HR=26, floor=27, pedometer=28, stress=29)
// are NOT SAP message ids. The wire protocol uses the Moden command ids below.
//
// Command ids / ack headers / Health field ids were recovered by yuriyurin from
// Samsung's Fit3 plugin 2.2.14.26071041N. Unknown record layouts are rejected;
// we only publish a metric when both the enclosing data type and a plausible
// known field exist.

import Foundation

public enum SapHealthCommand {
    public static let checkStatus = 1
    public static let syncData = 2
    public static let requestData = 3
    public static let wearableMsg = 4
    public static let pedometerBackSync = 7 // 0x87 request / 0xC7 response
    public static let wearableRequestCapability = 32
    public static let mobileRequestCapability = 33
    public static let gmRequestCapability = 34
    public static let gmCapabilityNoti = 35
    public static let pluginHealthCapabilityRequest = 52 // literal 0x34 from HealthDataManager
}

/// Health data type ids (ModenParameterConstants.FeatureDataType).
public enum HealthDataType {
    public static let pedoStepCount = 7
    public static let heartRate = 10
    public static let sleep = 16
    public static let sleepStage = 17
    public static let stress = 19
    public static let oxygenSaturation = 112
    public static let floorsClimbed = 141
}

// GM capability parameter ids.
private let gmStatus: UInt8 = 0xD0
private let gmResult: UInt8 = 0xD1
private let gmHostShealthVersion: UInt8 = 0xD2
private let gmHostShealthTargetVersion: UInt8 = 0xD3
private let gmSequenceNumber: UInt8 = 0xE0
private let gmHealthProtocolVersion: UInt8 = 0xE1
private let gmShealthInstalled: Int = 2
private let gmResultSuccess: Int = 0

// Capability field ids used by Fit3 / Samsung Health (CapaParamNameConstants).
private let capaProtocolVersion: UInt8 = 0xA1
private let capaShealthVersion: UInt8 = 0xA2
private let capaConfig: UInt8 = 0xAC
private let capaLaunchSupport: UInt8 = 0xAD
private let capaBinning: UInt8 = 0xAE
private let capaProtocolFeature: UInt8 = 0xAF
private let capaSyncAddress: UInt8 = 0xB1
private let capaTrackerFeature: UInt8 = 0xB3
private let capaMessageType: UInt8 = 0xC0
private let capaSender: UInt8 = 0xC1
private let capaReceiver: UInt8 = 0xC2
private let capaWearableMessage: UInt8 = 0xC3

// Samsung Health 7.0.6.011 advertises protocol 4.51 (major 4, BCD minor 0x51).
private let hostProtocolMajor = 4
private let hostProtocolMinorBCD = 0x51
private let emulatedShealthVersion = 7_006_011
private let fit3MinShealthVersion = 6_040_000

// Health record time base: seconds since 1990-01-01 (631_152_000 s after Unix epoch).
let healthTimeBaseSeconds: Int64 = 631_152_000

// MARK: - Vital records (heart rate etc.)

/// Strict decoder for the length-prefixed Health records used by Fit3.
/// Port of Fit3VitalCodec.kt. Unknown layouts are rejected, never guessed.
public enum VitalCodec {
    public struct Sample: Equatable {
        public let type: Int
        public let startMillis: Int64?
        public let endMillis: Int64?
        public let value: Int?
        public let min: Int?
        public let max: Int?
        public var measuredAt: Int64? { endMillis ?? startMillis }
    }

    public static func parse(_ message: [UInt8]) -> [Sample]? {
        guard message.count >= 12, Int(message[0]) & 0xff == 0x82,
              Int(message[2]) & 0xff == 0xE0 else { return nil }
        let type = Int(message[5]) & 0xff
        guard [10, 16, 19, 112].contains(type) else { return nil }
        var offset = 6
        var samples: [Sample] = []
        for _ in 0..<128 {
            guard offset + 5 <= message.count else { return nil }
            let more = Int(message[offset]); offset += 1
            guard (0...1).contains(more) else { return nil }
            let length = Int(le32(message, offset))
            offset += 4
            guard length > 0, length <= 65_536, offset + length <= message.count else { return nil }
            guard let sample = parseRecord(type, message, offset, offset + length) else { return nil }
            samples.append(sample)
            offset += length
            if more == 0 { return samples }
        }
        return nil
    }

    private static func parseRecord(_ type: Int, _ bytes: [UInt8], _ start: Int, _ end: Int) -> Sample? {
        var fields: [Int: ArraySlice<UInt8>] = [:]
        var offset = start
        while offset < end {
            let id = Int(bytes[offset]); offset += 1
            let width = fieldWidth(type, id)
            guard width != 0 else { return nil }
            if width < 0 {
                guard offset + 4 <= end else { return nil }
                let blobLength = Int(le32(bytes, offset))
                offset += 4
                guard blobLength >= 0, blobLength <= 65_536, offset + blobLength <= end else { return nil }
                offset += blobLength
            } else {
                guard offset + width <= end else { return nil }
                fields[id] = bytes[offset..<(offset + width)]
                offset += width
            }
        }
        let startTime = fields[1].map { healthTime(Array($0)) }
        let endTime = fields[2].map { healthTime(Array($0)) }
        let value: Int?
        let min: Int?
        let max: Int?
        switch type {
        case 10:
            value = fields[32].map { Int($0.first!) }
            min = fields[33].map { Int($0.first!) }
            max = fields[34].map { Int($0.first!) }
        case 19:
            value = fields[96].map { Int($0.first!) }
            min = fields[102].map { Int($0.first!) }
            max = fields[103].map { Int($0.first!) }
        case 112:
            value = fields[169].map { Int($0.first!) }
            min = fields[171].map { Int($0.first!) }
            max = fields[172].map { Int($0.first!) }
        default:
            value = nil; min = nil; max = nil
        }
        return Sample(type: type, startMillis: startTime, endMillis: endTime,
                      value: value, min: min, max: max)
    }

    private static func fieldWidth(_ type: Int, _ id: Int) -> Int {
        if [1, 2, 3, 5, 151, 153].contains(id) { return 4 }
        switch type {
        case 10:
            switch id {
            case 32, 33, 34, 35: return 1
            case 36: return -1 // minute bins: 4-byte length, then packed entries
            case 37: return 2
            default: return 0
            }
        case 19:
            switch id {
            case 96, 102, 103: return 1
            case 97: return 4
            case 98: return -1
            default: return 0
            }
        case 112:
            switch id {
            case 117: return 16
            case 169, 170, 171, 172: return 1
            case 173: return 2
            case 174: return 4
            case 175: return -1
            default: return 0
            }
        case 16:
            switch id {
            case 28...37: return 2
            case 40, 80: return 4
            case 81, 83, 86: return 1
            case 82, 117: return 16
            default: return 0
            }
        default: return 0
        }
    }
}

func healthTime(_ raw: [UInt8]) -> Int64 {
    (Int64(le32(raw, 0)) & 0xffff_ffff + healthTimeBaseSeconds) * 1000
}

func le32(_ bytes: [UInt8], _ offset: Int) -> Int32 {
    guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
    var v: UInt32 = 0
    for i in 0..<4 { v |= UInt32(bytes[offset + i]) << (i * 8) }
    return Int32(bitPattern: v)
}

// MARK: - Pedometer step records

public struct Fit3StepRecord: Equatable {
    public var count: Int
    public var walk: Int
    public var run: Int
    public var distanceMeters: Double
    public var calories: Double
    public var durationMillis: Int

    public func isValid() -> Bool {
        (0...100_000).contains(count) && (0...count).contains(walk) && (0...count).contains(run)
            && walk + run <= count && calories.isFinite && (0.0...10_000.0).contains(calories)
            && distanceMeters.isFinite && (0.0...100_000.0).contains(distanceMeters)
            && (0...86_400_000).contains(durationMillis)
    }
}

public enum PedometerMerge {
    /// Canonicalises start times to firmware minute bins. Retransmission or a reset
    /// must not add a second copy of the same bin. Only records on the local day of
    /// `now` (and not in the future by more than 5 minutes) survive.
    /// Port of Fit3PedometerBackSync.mergeRecords.
    public static func mergeRecords(old: [Int64: Fit3StepRecord],
                                    fresh: [Int64: Fit3StepRecord],
                                    nowMillis: Int64,
                                    zone: TimeZone = .current) -> [Int64: Fit3StepRecord] {
        let day = localDay(millis: nowMillis, zone: zone)
        var result: [Int64: Fit3StepRecord] = [:]
        for (at, record) in Array(old) + Array(fresh) {
            guard localDay(millis: at, zone: zone) == day,
                  at <= nowMillis + 5 * 60_000, record.isValid() else { continue }
            let minute = at / 60_000 * 60_000
            if let previous = result[minute] {
                if record.count > previous.count ||
                    (record.count == previous.count && record.durationMillis >= previous.durationMillis) {
                    result[minute] = record
                }
            } else {
                result[minute] = record
            }
        }
        return result
    }

    static func localDay(millis: Int64, zone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.ordinality(of: .day, in: .era, for: Date(milliseconds: millis)) ?? 0
    }
}

public extension Date {
    init(milliseconds: Int64) { self.init(timeIntervalSince1970: Double(milliseconds) / 1000) }
    var milliseconds: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }
}

// MARK: - Health codec

public enum HealthCodecEvent: Equatable {
    case checkStatus
    case gmCapabilityRequest
    case wearableCapabilityRequest
    case capability
    case syncData
    case pedometerBackSync
    case requestData
    case wearableMessage
    case other
}

/// Immutable session state – port of Fit3HealthCodec.State (trimmed to the fields
/// Fit3BridgeFree uses: step intervals and heart-rate vitals).
public struct HealthCodecState: Equatable {
    public var steps: Int?
    public var walkSteps: Int?
    public var runSteps: Int?
    public var distanceMeters: Double?
    public var activeCalories: Double?
    public var activeMinutes: Int?
    public var heartRate: Int?
    public var heartRateMin: Int?
    public var heartRateMax: Int?
    public var heartRateAt: Int64?
    public var stepHistory: [Int] = []
    public var stepRecords: [Int64: Fit3StepRecord] = [:]
    public var stepDay: Int?
    public var sessionReady = false
    public var healthProtocolVersion: Int?
    public var lastSyncMillis: Int64?
    public var lastSuccessfulSyncMillis: Int64?
    public var stepsPartial = false

    public init() {}
}

public struct HealthIncoming {
    public let state: HealthCodecState
    public let reply: [UInt8]?
    public let status: String
    public let event: HealthCodecEvent
    public let parsedDataTypes: Set<Int>
}

public enum HealthCodec {
    public static func checkStatusRequest(_ sequence: Int) -> [UInt8] {
        precondition((1...0xffff).contains(sequence))
        return [0x01, 0x01, gmSequenceNumber, UInt8(sequence & 0xff), UInt8((sequence >> 8) & 0xff)]
    }

    /// The official plugin sends this one-byte request when registering a new Fit3 host.
    public static let mobileCapabilityRequest: [UInt8] = [0x34]

    /// Stock REQUEST_DATA has no count byte. Its DeviceInfo body is 25 bytes.
    /// A zero last-sync cursor asks for a full exchange; never invent phone step totals.
    public static func requestData(_ sequence: Int, nowMillis: Int64) -> [UInt8] {
        precondition((1...0xffff).contains(sequence))
        let end = Int32(clamping: max(0, nowMillis / 1000 - 631_152_000))
        var out: [UInt8] = [3]
        out += SAMessage.shortParam(Int(gmSequenceNumber), sequence)
        out += [5, 25, 1, 0, 2, 0, 0, 3, 4, 51]
        out += SAMessage.intParam(4, 0)
        out += SAMessage.intParam(5, 0)
        out += SAMessage.intParam(6, end)
        out += [7, 1]
        return out
    }

    public static func sequence(_ message: [UInt8]) -> Int? {
        guard let h = SAMessage.parseHeader(message) else { return nil }
        let offset: Int
        if h.id == SapHealthCommand.pedometerBackSync {
            offset = 1
        } else if h.id == SapHealthCommand.syncData || h.format == SAMessage.formatVariable {
            offset = 2
        } else {
            offset = 1
        }
        guard offset < message.count, Int(message[offset]) & 0xff == 0xE0 else { return nil }
        return (Int(message[offset + 1]) & 0xff) | ((Int(message[offset + 2]) & 0xff) << 8)
    }

    public static func isRequestDataSuccess(_ message: [UInt8], expectedSequence: Int) -> Bool {
        message.count >= 8 && message[0] == 0x43 && sequence(message) == expectedSequence &&
            Array(message[4..<8]) == [4, 2, 1, 1]
    }

    public static func handle(_ previous: HealthCodecState, _ message: [UInt8],
                              nowMillis: Int64) -> HealthIncoming {
        guard let h = SAMessage.parseHeader(message) else {
            return HealthIncoming(state: previous, reply: nil, status: "无效的 Health 数据包",
                                  event: .other, parsedDataTypes: [])
        }
        let isRequest = h.type == SAMessage.typeRequest
        switch h.id {
        case SapHealthCommand.gmRequestCapability:
            guard isRequest, let gm = parseGmRequest(message) else {
                return HealthIncoming(state: touched(previous, nowMillis), reply: nil,
                                      status: "收到 Health capability 响应", event: .capability,
                                      parsedDataTypes: [])
            }
            var state = previous
            state.sessionReady = true
            state.healthProtocolVersion = gm.protocolVersion
            return HealthIncoming(state: state, reply: gmCapabilityResponse(gm),
                                  status: "Health 握手：手环协议 \(gm.protocolVersion)",
                                  event: .gmCapabilityRequest, parsedDataTypes: [])
        case SapHealthCommand.wearableRequestCapability:
            guard isRequest, let seq = parseCapabilitySequence(message) else {
                return HealthIncoming(state: touched(previous, nowMillis), reply: nil,
                                      status: "收到 Health wearable capability 响应",
                                      event: .capability, parsedDataTypes: [])
            }
            var state = previous
            state.sessionReady = true
            return HealthIncoming(state: state, reply: wearableCapabilityResponse(seq),
                                  status: "已应答手环 capability 请求（协议 4.51），等待 SYNC_DATA",
                                  event: .wearableCapabilityRequest, parsedDataTypes: [])
        case SapHealthCommand.gmCapabilityNoti, SapHealthCommand.mobileRequestCapability,
             SapHealthCommand.pluginHealthCapabilityRequest:
            return HealthIncoming(state: touched(previous, nowMillis), reply: nil,
                                  status: "Health capability 交换完成", event: .capability,
                                  parsedDataTypes: [])
        case SapHealthCommand.checkStatus:
            return HealthIncoming(state: touched(previous, nowMillis),
                                  reply: isRequest ? SAMessage.fixedResponse(SapHealthCommand.checkStatus) : nil,
                                  status: "Health 通道正常", event: .checkStatus, parsedDataTypes: [])
        case SapHealthCommand.syncData:
            return processSync(previous, message, nowMillis, isRequest)
        case SapHealthCommand.pedometerBackSync:
            return HealthIncoming(state: touched(previous, nowMillis), reply: nil,
                                  status: "收到步数回传响应", event: .pedometerBackSync,
                                  parsedDataTypes: [])
        case SapHealthCommand.requestData:
            return HealthIncoming(state: touched(previous, nowMillis),
                                  reply: isRequest ? requestDataEmptySuccessResponse(message) : nil,
                                  status: "手环向手机请求 Health 数据", event: .requestData,
                                  parsedDataTypes: [])
        case SapHealthCommand.wearableMsg:
            return HealthIncoming(state: touched(previous, nowMillis),
                                  reply: isRequest ? SAMessage.fixedResponse(SapHealthCommand.wearableMsg) : nil,
                                  status: "收到 Health wearable message", event: .wearableMessage,
                                  parsedDataTypes: [])
        default:
            return HealthIncoming(state: touched(previous, nowMillis), reply: nil,
                                  status: "未知的 Health 命令 \(h.id)", event: .other,
                                  parsedDataTypes: [])
        }
    }

    private static func touched(_ state: HealthCodecState, _ nowMillis: Int64) -> HealthCodecState {
        var s = state
        // lastTransportMillis is only informational here; keep the struct small.
        _ = nowMillis
        return s
    }

    private static func processSync(_ previous: HealthCodecState, _ message: [UInt8],
                                    _ nowMillis: Int64, _ isRequest: Bool) -> HealthIncoming {
        let (merged, types) = mergeSyncPayload(previous, message, nowMillis)
        return HealthIncoming(
            state: merged,
            reply: isRequest ? syncDataSuccessResponse(message) : nil,
            status: types.isEmpty ? "收到 Health sync 数据"
                : "收到 Health 数据：\(types.map { dataTypeName($0) }.joined(separator: ", "))",
            event: .syncData,
            parsedDataTypes: types,
        )
    }

    /// Plugin generateTheSyncByte(): 42 02 E0 <seq LE> 04 02 01 SUCCESS.
    private static func syncDataSuccessResponse(_ request: [UInt8]) -> [UInt8]? {
        guard request.count >= 5, Int(request[2]) & 0xff == gmSequenceNumber,
              let sequence = SAMessage.readLEShort(request, 3) else { return nil }
        return [0x42, 0x02, gmSequenceNumber, UInt8(sequence & 0xff), UInt8((sequence >> 8) & 0xff),
                0x04, 0x02, 0x01, 0x01]
    }

    private static func requestDataEmptySuccessResponse(_ request: [UInt8]) -> [UInt8]? {
        guard request.count >= 4, Int(request[1]) & 0xff == gmSequenceNumber,
              let sequence = SAMessage.readLEShort(request, 2) else { return nil }
        return [0x43, gmSequenceNumber, UInt8(sequence & 0xff), UInt8((sequence >> 8) & 0xff),
                0x04, 0x02, 0x01, 0x01]
    }

    /// Extracts the E0 sequence number that starts Fit3 capability requests.
    private static func parseCapabilitySequence(_ message: [UInt8]) -> Int? {
        if message.count >= 5, Int(message[2]) & 0xff == gmSequenceNumber {
            return SAMessage.readLEShort(message, 3)
        }
        guard message.count > 4 else { return nil }
        for i in 2..<(message.count - 2) where Int(message[i]) & 0xff == gmSequenceNumber {
            return SAMessage.readLEShort(message, i + 1)
        }
        return nil
    }

    private struct GmRequest {
        var sequence: Int
        var protocolVersion: Int
    }

    private static func parseGmRequest(_ message: [UInt8]) -> GmRequest? {
        guard let h = SAMessage.parseHeader(message),
              h.id == SapHealthCommand.gmRequestCapability,
              h.format == SAMessage.formatVariable, message.count >= 2 else { return nil }
        let count = Int(message[1]) & 0xff
        var i = 2
        var seq: Int?
        var protocolVersion: Int?
        for _ in 0..<count {
            guard i < message.count else { break }
            let id = Int(message[i]); i += 1
            switch UInt8(id) {
            case gmSequenceNumber:
                seq = SAMessage.readLEShort(message, i); i += 2
            case gmHealthProtocolVersion:
                protocolVersion = SAMessage.readLEShort(message, i); i += 2
            case gmStatus, gmResult:
                i += 1
            case gmHostShealthVersion, gmHostShealthTargetVersion:
                i += 4
            default:
                break // Unknown GM request params cannot be safely sized; stop parsing.
            }
        }
        guard let s = seq, let p = protocolVersion else { return nil }
        return GmRequest(sequence: s, protocolVersion: p)
    }

    /// Official GM capability response fields: status/result, host/current target
    /// versions, the request sequence and Health protocol version.
    private static func gmCapabilityResponse(_ req: GmRequest) -> [UInt8] {
        var out: [UInt8] = [SAMessage.header(format: SAMessage.formatVariable,
                                             type: SAMessage.typeResponse,
                                             id: SapHealthCommand.gmRequestCapability), 6]
        out += SAMessage.byteParam(Int(gmStatus), gmShealthInstalled)
        out += SAMessage.byteParam(Int(gmResult), gmResultSuccess)
        out += SAMessage.intParam(Int(gmHostShealthVersion), Int32(clamping: emulatedShealthVersion))
        out += SAMessage.intParam(Int(gmHostShealthTargetVersion), Int32(clamping: fit3MinShealthVersion))
        out += SAMessage.shortParam(Int(gmSequenceNumber), req.sequence)
        out += SAMessage.shortParam(Int(gmHealthProtocolVersion), req.protocolVersion)
        return out
    }

    /// Mobile capability generated from the supplied Samsung Health 7.0.6.011 APK by
    /// yuriyurin/Fit3-App. Keep each JSON capability below 255 bytes so it uses Fit3's
    /// one-byte string length form observed in the real A0 capability packet.
    private static func wearableCapabilityResponse(_ sequence: Int) -> [UInt8] {
        func json(_ entries: (String, String)...) -> String {
            "{" + entries.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",") + "}"
        }
        func quoted(_ value: String) -> String { "\"\(value)\"" }

        let binning = json(("pedometer", "4"))
        let protocolFeature = json(("wearable_messaging", "true"), ("compression", "true"),
                                   ("wm_chunk_size", "10000"), ("sync_duration", "30"),
                                   ("blob_compression", "true"))
        let syncAddress = json(("common_sync",
                                quoted("com.samsung.android.app.shealth.wearable.syncmanager")))
        let trackerFeature = json(
            ("pedometer_sync", json(("support_wearable_all_step", "true"))),
            ("goal_support", json(("pedometer", "1"), ("floor", "1"), ("water", "0"))),
            ("daily_activity", json(("support", "false"))),
            ("dashboard_config_sync", json(("version", "1000"), ("is_support", "true"))))
        let config = json(("os", quoted("android")), ("os_version", quoted("16")),
                          ("country_iso", quoted("")), ("one_ui_version", "-1"))
        let wearableMessage = json(("message_version", "5.18"), ("message_support", "true"),
                                   ("message_compression", "true"),
                                   ("message_compression_format", quoted("gzip")),
                                   ("message_size", "10000"))
        let launchSupport = json(("support", "false"),
                                 ("target_list", quoted("settings.band.manage_exercises")))

        var out: [UInt8] = [SAMessage.header(format: SAMessage.formatVariable,
                                             type: SAMessage.typeResponse,
                                             id: SapHealthCommand.wearableRequestCapability), 13]
        out += SAMessage.shortParam(Int(gmSequenceNumber), sequence)
        out += [capaProtocolVersion, UInt8(hostProtocolMajor), UInt8(hostProtocolMinorBCD)]
        out += SAMessage.intParam(Int(capaShealthVersion), Int32(clamping: emulatedShealthVersion))
        out += stringParam(Int(capaMessageType), "com.samsung.android.app.shealth.RESPONSE_CAPABILITY")
        out += stringParam(Int(capaSender), "shealth")
        out += stringParam(Int(capaReceiver), "wearable")
        out += stringParam(Int(capaBinning), binning)
        out += stringParam(Int(capaProtocolFeature), protocolFeature)
        out += stringParam(Int(capaSyncAddress), syncAddress)
        out += stringParam(Int(capaTrackerFeature), trackerFeature)
        out += stringParam(Int(capaConfig), config)
        out += stringParam(Int(capaWearableMessage), wearableMessage)
        out += stringParam(Int(capaLaunchSupport), launchSupport)
        return out
    }

    private static func stringParam(_ id: Int, _ value: String) -> [UInt8] {
        var raw = Array(value.utf8)
        if raw.count > 255 { raw = Array(raw.prefix(255)) }
        return [UInt8(id), UInt8(raw.count)] + raw
    }

    private static func mergeSyncPayload(_ previous: HealthCodecState, _ message: [UInt8],
                                         _ nowMillis: Int64) -> (HealthCodecState, Set<Int>) {
        var next = previous
        var types: Set<Int> = []

        // Actual AZA3 captures contain type 7 interval records before any day-summary
        // packet. Canonicalise start times to firmware minute bins.
        if let intervals = parsePedometerIntervals(message) {
            types.insert(HealthDataType.pedoStepCount)
            var base = previous
            let day = PedometerMerge.localDay(millis: nowMillis, zone: .current)
            if let previousDay = previous.stepDay, previousDay != day {
                base.steps = nil
                base.walkSteps = nil
                base.runSteps = nil
                base.distanceMeters = nil
                base.activeCalories = nil
                base.activeMinutes = nil
                base.stepHistory = []
                base.stepRecords = [:]
                base.stepsPartial = false
            }
            let records = PedometerMerge.mergeRecords(old: base.stepRecords, fresh: intervals,
                                                      nowMillis: nowMillis)
            next = base
            next.stepRecords = records
            next.stepDay = day
            let values = Array(records.values)
            if !values.isEmpty {
                let partialSteps = values.reduce(0) { $0 + $1.count }
                next.steps = partialSteps
                next.stepsPartial = true
                next.walkSteps = values.reduce(0) { $0 + $1.walk }
                next.runSteps = values.reduce(0) { $0 + $1.run }
                next.distanceMeters = values.reduce(0.0) { $0 + $1.distanceMeters }
                next.activeCalories = values.reduce(0.0) { $0 + $1.calories }
                // Type-7 field 22 is the official pedometer interval duration in ms.
                let minutes = Int(min(max(values.reduce(0) { $0 + $1.durationMillis } / 60_000, 0), 1_440))
                next.activeMinutes = minutes
                if let newSteps = next.steps, base.steps != newSteps {
                    next.stepHistory = (base.stepHistory + [newSteps]).suffix(24)
                }
                next.lastSyncMillis = nowMillis
            }
        }

        // Heart-rate (and other vital) records: length-prefixed feature records.
        if let samples = VitalCodec.parse(message), let first = samples.first {
            types.insert(first.type)
            guard first.type == HealthDataType.heartRate else { return (next, types) }
            let samplesWithTime = samples.filter { $0.measuredAt != nil }
            guard let sample = samplesWithTime.max(by: { ($0.measuredAt ?? 0) < ($1.measuredAt ?? 0) }),
                  let at = sample.measuredAt else { return (next, types) }
            let maxFuture = nowMillis + 5 * 60_000
            let maxAge: Int64 = 24 * 60 * 60_000
            guard (nowMillis - maxAge)...maxFuture ~= at else { return (next, types) }
            if let hr = sample.value, (25...250).contains(hr),
               (previous.heartRateAt ?? Int64.min) <= at {
                next.heartRate = hr
                if let mn = sample.min, (25...250).contains(mn) { next.heartRateMin = mn }
                if let mx = sample.max, (25...250).contains(mx) { next.heartRateMax = mx }
                next.heartRateAt = at
                next.lastSyncMillis = nowMillis
            }
        }

        return (next, types)
    }

    /// Samsung's type-7 PedometerStepCount: continuation byte, then 12 fixed fields.
    static func parsePedometerIntervals(_ message: [UInt8]) -> [Int64: Fit3StepRecord]? {
        guard message.count >= 8, Int(message[0]) & 0xff == 0x82,
              Int(message[2]) & 0xff == gmSequenceNumber,
              Int(message[5]) & 0xff == HealthDataType.pedoStepCount else { return nil }
        var result: [Int64: Fit3StepRecord] = [:]
        var i = 6
        for _ in 0..<128 {
            if i >= message.count { return result.isEmpty ? nil : result }
            let more = Int(message[i]); i += 1
            guard (0...1).contains(more) else { return nil }
            var start: Int64?
            var count: Int?
            var walk = 0
            var run = 0
            var distance = 0.0
            var calories = 0.0
            var duration = 0
            let fields = [5, 1, 2, 3, 16, 17, 18, 19, 20, 21, 22, 23]
            for field in fields {
                guard i < message.count, Int(message[i]) & 0xff == field else { return nil }
                i += 1
                let width = field == 23 ? 1 : 4
                guard i + width <= message.count else { return nil }
                if width == 4 {
                    let raw = le32(message, i)
                    switch field {
                    case 1: start = (Int64(raw) & 0xffff_ffff) * 1000 + healthTimeBaseSeconds * 1000
                    case 16: count = (0...100_000).contains(Int(raw)) ? Int(raw) : nil
                    case 17: distance = Double(Float(bitPattern: UInt32(bitPattern: raw)))
                    case 19: calories = Double(Float(bitPattern: UInt32(bitPattern: raw)))
                    case 20: run = Int(raw)
                    case 21: walk = Int(raw)
                    case 22: duration = Int(raw)
                    default: break
                    }
                }
                i += width
            }
            guard let s = start, let c = count else { return nil }
            guard (0...c).contains(walk), (0...c).contains(run),
                  distance.isFinite, (0.0...100_000.0).contains(distance),
                  calories.isFinite, (0.0...10_000.0).contains(calories),
                  (0...86_400_000).contains(duration) else { return nil }
            result[s] = Fit3StepRecord(count: c, walk: walk, run: run, distanceMeters: distance,
                                       calories: calories, durationMillis: duration)
            if more == 0 { return result }
        }
        return nil
    }

    public static func dataTypeName(_ type: Int) -> String {
        switch type {
        case HealthDataType.pedoStepCount: return "步数"
        case HealthDataType.heartRate: return "心率"
        case HealthDataType.sleep: return "睡眠"
        case HealthDataType.sleepStage: return "睡眠阶段"
        case HealthDataType.stress: return "压力"
        case HealthDataType.oxygenSaturation: return "血氧"
        case HealthDataType.floorsClimbed: return "楼层"
        default: return "类型 \(type)"
        }
    }
}

// MARK: - Health large-data chunks

/// Reassembles Health large-data chunks (id 63) before the normal Health decoder
/// sees them. Port of Fit3HealthLargeDataReceiver.kt.
public final class HealthLargeDataReceiver {
    public struct Result {
        public let payload: [UInt8]?
        public let reply: [UInt8]?
    }

    private var chunks: [UInt8] = []
    private var nextChunk = 0

    public init() {}

    public func reset() {
        chunks.removeAll()
        nextChunk = 0
    }

    /// Returns nil for a packet that is not a Health large-data chunk.
    public func accept(_ message: [UInt8]) -> Result? {
        guard let first = message.first, Int(first) & 0x3f == Self.chunkId else { return nil }
        if message.count < Self.headerSize {
            reset()
            return Result(payload: nil, reply: Self.acknowledgement(0, accepted: false))
        }
        let flag = Int(message[1]) & 0x03
        var number: UInt32 = 0
        for i in 0..<4 { number |= UInt32(message[2 + i]) << (i * 8) }
        let index = Int(number)
        if flag == Self.first && index == 0 { reset() }
        if !(Self.first...Self.last).contains(flag) || (flag == Self.first) != (index == 0) ||
            index != nextChunk || nextChunk >= Self.maxChunks ||
            chunks.count + message.count - Self.headerSize > Self.maxBytes {
            reset()
            return Result(payload: nil,
                          reply: Self.acknowledgement(min(index, Int(Int32.max)), accepted: false))
        }
        chunks.append(contentsOf: message[Self.headerSize...])
        nextChunk += 1
        if flag != Self.last { return Result(payload: nil, reply: nil) }
        let payload = chunks
        let reply = Self.acknowledgement(nextChunk, accepted: true)
        reset()
        return Result(payload: payload, reply: reply)
    }

    private static func acknowledgement(_ chunkCount: Int, accepted: Bool) -> [UInt8] {
        let v = UInt32(truncatingIfNeeded: Int32(chunkCount))
        return [0x3e, accepted ? 0x09 : 0x08,
                UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
    }

    private static let chunkId = 63
    private static let headerSize = 6
    private static let first = 0
    private static let last = 2
    private static let maxChunks = 256
    private static let maxBytes = 1024 * 1024
}

// MARK: - SAMessage helpers used above but missing from the base package

public extension SAMessage {
    static func readLEShort(_ bytes: [UInt8], _ offset: Int) -> Int? {
        guard offset >= 0, offset + 2 <= bytes.count else { return nil }
        return (Int(bytes[offset]) & 0xff) | ((Int(bytes[offset + 1]) & 0xff) << 8)
    }

    static func fixedResponse(_ id: Int) -> [UInt8] {
        [header(format: formatFixed, type: typeResponse, id: id)]
    }
}
