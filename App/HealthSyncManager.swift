import Foundation
import Fit3Kit
import Combine
#if os(iOS)
import HealthKit
#endif

/// Bridges the Fit3 Health service (SAP 10) to Apple Health (HealthKit).
/// Protocol state machine lives in Fit3Kit (tested on macOS); this class owns the
/// session, the HealthKit writes and the user-facing state.
final class HealthSyncManager: ObservableObject {
    static let shared = HealthSyncManager()

    // MARK: Published UI state
    @Published private(set) var todaySteps: Int?
    @Published private(set) var walkSteps: Int?
    @Published private(set) var distanceMeters: Double?
    @Published private(set) var heartRate: Int?
    @Published private(set) var heartRateAt: Date?
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastStatus = "尚未同步"
    @Published private(set) var healthKitAuthorized = false
    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: "health.enabled") }
    }

    // MARK: Session state
    private var state = HealthCodecState()
    private let largeData = HealthLargeDataReceiver()
    private var capabilityReady = false
    private var probeSent = false
    private var pendingRequest: Int?
    private var pendingRequestAt = Date()
    private var requestSequence = 10_000
    private var writtenStepKeys: Set<Int64> = []
    private var lastWrittenHeartRateAt: Int64 = 0

    /// Set by BandManager once the Bluetooth session exists.
    var send: (([UInt8]) -> Void)?

    private let defaults = UserDefaults.standard
    #if os(iOS)
    private let healthStore = HKHealthStore()
    #endif

    private init() {
        enabled = defaults.object(forKey: "health.enabled") as? Bool ?? true
        let keys = defaults.array(forKey: "health.writtenSteps") as? [Int64] ?? []
        writtenStepKeys = Set(keys)
        lastWrittenHeartRateAt = defaults.double(forKey: "health.lastHeartRateAt")
    }

    // MARK: Session lifecycle (called from BandManager)

    func connectionReset() {
        state = HealthCodecState()
        largeData.reset()
        capabilityReady = false
        probeSent = false
        pendingRequest = nil
    }

    /// Sent after the band setup finishes, mirroring the official Android plugin flow.
    func probe() {
        send?(HealthCodec.mobileCapabilityRequest)
        probeSent = true
        Logbook.shared.add("Health: 已发送 capability 探测")
    }

    func requestSnapshot() {
        if capabilityReady {
            beginRequestData()
        } else if !probeSent {
            probe()
        }
    }

    private func beginRequestData() {
        guard capabilityReady else { return }
        let now = Date()
        if pendingRequest != nil, Date().timeIntervalSince(pendingRequestAt) < 45 { return }
        requestSequence = requestSequence >= 0xffff ? 1 : requestSequence + 1
        pendingRequest = requestSequence
        pendingRequestAt = now
        send?(HealthCodec.requestData(requestSequence, nowMillis: now.milliseconds))
        Logbook.shared.add("Health: 请求数据 (seq \(requestSequence))")
    }

    // MARK: Incoming SAP service-10 messages

    func handleIncoming(_ message: [UInt8]) {
        let largeDataResult = largeData.accept(message)
        if let result = largeDataResult, result.payload == nil {
            if let reply = result.reply { send?(reply) }
            return
        }
        let payload = largeDataResult?.payload ?? message
        let now = Date()
        let incoming = HealthCodec.handle(state, payload, nowMillis: now.milliseconds)
        state = incoming.state
        if let reply = largeDataResult?.reply { send?(reply) }
        if let reply = incoming.reply { send?(reply) }
        Logbook.shared.add("Health: \(incoming.status)")

        switch incoming.event {
        case .wearableCapabilityRequest where incoming.reply != nil:
            capabilityReady = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.beginRequestData()
            }
        case .syncData:
            writeTodayStepsToHealthKit()
            writeHeartRateToHealthKit()
        case .requestData:
            if let seq = pendingRequest, HealthCodec.isRequestDataSuccess(payload, expectedSequence: seq) {
                pendingRequest = nil
            }
        default:
            break
        }

        publishState()
    }

    private func publishState() {
        todaySteps = state.steps
        walkSteps = state.walkSteps
        distanceMeters = state.distanceMeters
        if let at = state.heartRateAt {
            heartRate = state.heartRate
            heartRateAt = Date(milliseconds: at)
        }
        if let sync = state.lastSyncMillis { lastSync = Date(milliseconds: sync) }
        lastStatus = state.lastSuccessfulSyncMillis != nil ? "最近同步成功" : lastStatus
    }

    // MARK: HealthKit

    #if os(iOS)
    func requestAuthorization() {
        guard HKHealthStore.isHealthDataAvailable() else {
            healthKitAuthorized = false
            lastStatus = "此设备不支持 Apple Health"
            return
        }
        let types: Set<HKSampleType> = [
            HKQuantityType(.stepCount),
            HKQuantityType(.heartRate),
            HKQuantityType(.distanceWalkingRunning),
        ]
        healthStore.requestAuthorization(toShare: types, read: nil) { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.healthKitAuthorized = success
                self.lastStatus = success
                    ? "已获得 Apple Health 写入权限"
                    : "Apple Health 授权失败：\(error?.localizedDescription ?? "未知错误")"
                Logbook.shared.add("HealthKit 授权: \(success)")
            }
        }
    }

    /// Writes every not-yet-written minute-bin step record for today.
    /// Dedupe: the band replays the same bins after reconnect, so each start
    /// timestamp is written only once.
    private func writeTodayStepsToHealthKit() {
        guard enabled, healthKitAuthorized else { return }
        let stepType = HKQuantityType(.stepCount)
        let distanceType = HKQuantityType(.distanceWalkingRunning)
        var dirty = false
        for (startMillis, record) in state.stepRecords.sorted(by: { $0.key < $1.key }) {
            guard record.count > 0, !writtenStepKeys.contains(startMillis) else { continue }
            let start = Date(milliseconds: startMillis)
            // Records are minute bins; a zero duration still maps to one minute.
            let end = start.addingTimeInterval(TimeInterval(max(record.durationMillis, 60_000)) / 1000)
            let samples: [HKQuantitySample] = [
                HKQuantitySample(type: stepType,
                                 quantity: HKQuantity(unit: .count(), doubleValue: Double(record.count)),
                                 start: start, end: end),
                HKQuantitySample(type: distanceType,
                                 quantity: HKQuantity(unit: .meter(), doubleValue: record.distanceMeters),
                                 start: start, end: end),
            ]
            healthStore.save(samples) { [weak self] success, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if success {
                        self.writtenStepKeys.insert(startMillis)
                        dirty = true
                        Logbook.shared.add("HealthKit: +\(record.count) 步 @ \(start)")
                    } else {
                        Logbook.shared.add("HealthKit 写入失败: \(error?.localizedDescription ?? "?")")
                    }
                }
            }
        }
        pruneWrittenKeys()
        if dirty { persistWrittenKeys() }
    }

    private func writeHeartRateToHealthKit() {
        guard enabled, healthKitAuthorized,
              let at = state.heartRateAt, let bpm = state.heartRate,
              at > lastWrittenHeartRateAt else { return }
        let type = HKQuantityType(.heartRate)
        let start = Date(milliseconds: at - 60_000)
        let sample = HKQuantitySample(type: type,
                                      quantity: HKQuantity(unit: .internationalUnit().unitDivided(by: .minute()),
                                                           doubleValue: Double(bpm)),
                                      start: start, end: Date(milliseconds: at))
        healthStore.save(sample) { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if success {
                    self.lastWrittenHeartRateAt = at
                    self.defaults.set(Double(at), forKey: "health.lastHeartRateAt")
                    Logbook.shared.add("HealthKit: 心率 \(bpm) bpm @ \(Date(milliseconds: at))")
                } else {
                    Logbook.shared.add("HealthKit 心率写入失败: \(error?.localizedDescription ?? "?")")
                }
            }
        }
    }

    private func pruneWrittenKeys() {
        guard writtenStepKeys.count > 4_000 else { return }
        writtenStepKeys = Set(writtenStepKeys.sorted().suffix(2_000))
    }

    private func persistWrittenKeys() {
        defaults.set(Array(writtenStepKeys.sorted().suffix(4_000)), forKey: "health.writtenSteps")
    }
    #else
    func requestAuthorization() {}
    private func writeTodayStepsToHealthKit() {}
    private func writeHeartRateToHealthKit() {}
    #endif
}
