import Foundation
import Network
import CoreBluetooth
import Combine

final class ELM327Connection: NSObject, ObservableObject {
    @Published var state: ConnectionState = .disconnected
    @Published var transport: ELMTransport = .bluetooth
    @Published var wifiHost: String = "192.168.0.10"
    @Published var wifiPort: UInt16 = 35000
    @Published var logMessages: [String] = []
    @Published var discoveredDevices: [(name: String, id: String)] = []
    @Published var bleReport: [String] = []
    @Published var selectedTX = ""
    @Published var selectedRX = ""
    @Published var bleRSSI = 0
    @Published var txCandidates: [String] = []
    @Published var rxCandidates: [String] = []

    var onRawData: ((Data) -> Void)?
    var onResponse: ((String) -> Void)?

    private var tcpConnection: NWConnection?
    private var centralManager: CBCentralManager?
    private var connectedPeripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var allCharacteristics: [CBCharacteristic] = []

    var bleDiagnosticText: String {
        (["Состояние: \(state.rawValue)", "Адаптер: \(connectedPeripheral?.name ?? "—")",
          "Identifier: \(connectedPeripheral?.identifier.uuidString ?? "—")", "RSSI: \(bleRSSI) dBm",
          "TX: \(selectedTX)", "RX: \(selectedRX)",
          "MTU: \(connectedPeripheral?.maximumWriteValueLength(for: .withResponse) ?? 0)"] + bleReport).joined(separator: "\n")
    }

    func selectTX(_ uuid: String) {
        guard let c = allCharacteristics.first(where: { $0.uuid.uuidString == uuid }),
              c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse) else { return }
        writeCharacteristic = c; selectedTX = uuid
        UserDefaults.standard.set(uuid, forKey: "tx.\(connectedPeripheral?.identifier.uuidString ?? "")")
        if notifyCharacteristic?.isNotifying == true { updateState(.ready) }
    }
    func selectRX(_ uuid: String) {
        guard let c = allCharacteristics.first(where: { $0.uuid.uuidString == uuid }),
              c.properties.contains(.notify) || c.properties.contains(.indicate) else { return }
        if let old = notifyCharacteristic, old.uuid != c.uuid { connectedPeripheral?.setNotifyValue(false, for: old) }
        notifyCharacteristic = c; selectedRX = uuid
        connectedPeripheral?.setNotifyValue(true, for: c)
        UserDefaults.standard.set(uuid, forKey: "rx.\(connectedPeripheral?.identifier.uuidString ?? "")")
    }

    private var commandQueue: [ELMCommand] = []
    private var isProcessingCommand = false
    private var responseBuffer = ""
    private var currentCommand: ELMCommand?
    private var commandTimer: Timer?
    /// True after ATSP2: J1850 responses always start with "26 <addr>" (ATH1),
    /// anything else on the bus is unsolicited traffic (2D xx, B8 58, 23 A0 ...).
    private var isJ1850 = false

    // MARK: - Response token helpers (shared by the handlers)

    /// Hex byte tokens of a response, ignoring non-hex text such as "NO DATA".
    static func tokens(_ s: String) -> [String] {
        s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ").map { String($0).uppercased() }
            .filter { tok in tok.count == 2 && tok.allSatisfy { ch in ch.isHexDigit } }
    }

    /// Negative response "7F <sid> <code>" anywhere in the response, matched on
    /// byte tokens so data bytes that happen to be 7F/21/78 do not trigger it.
    static func hasNRC(_ s: String, code: UInt8) -> Bool {
        let t = tokens(s)
        guard t.count >= 3 else { return false }
        let c = String(format: "%02X", code)
        for i in 0..<(t.count - 2) where t[i] == "7F" && t[i + 2] == c { return true }
        return false
    }

    /// Positive response SID present as a token (e.g. "54" for ClearDTC).
    static func hasToken(_ s: String, _ byte: UInt8) -> Bool {
        tokens(s).contains(String(format: "%02X", byte))
    }

    private let elmServiceUUID = CBUUID(string: "FFF0")
    private let elmWriteUUID = CBUUID(string: "FFF2")
    private let elmNotifyUUID = CBUUID(string: "FFF1")

    override init() { super.init() }

    // MARK: - Public

    func connect() {
        switch transport {
        case .wifi: connectWiFi()
        case .bluetooth: connectBluetooth()
        }
    }

    func disconnect() {
        cancelQueuedCommands()
        commandTimer?.invalidate()
        currentCommand = nil
        isProcessingCommand = false
        responseBuffer = ""
        tcpConnection?.cancel(); tcpConnection = nil
        if let p = connectedPeripheral { centralManager?.cancelPeripheralConnection(p) }
        updateState(.disconnected)
    }

    func sendCommand(_ cmd: String, timeout: TimeInterval = 5.0, completion: ((String) -> Void)? = nil) {
        guard state == .ready || state == .busy else { completion?("BLE DISCONNECTED"); return }
        commandQueue.append(ELMCommand(cmd, timeout: timeout, completion: completion))
        processNextCommand()
    }

    /// Commands waiting or in flight. Pollers must not enqueue while this is
    /// non-zero: the 0.1 s live-data timer used to queue ~3 reads per answered
    /// read, so after 35 s the queue held a minute of stale reads and a smoke
    /// test's ATZ went out 63 s after START (emulator log 2026-09-23 20:29).
    var pendingCommands: Int { commandQueue.count + (isProcessingCommand ? 1 : 0) }

    /// Drop everything that has not been sent yet (the in-flight command is
    /// left alone so its response is still matched). Used before an init
    /// sequence so ATZ is not stuck behind queued block reads.
    func cancelQueuedCommands() {
        guard !commandQueue.isEmpty else { return }
        let dropped = commandQueue
        commandQueue.removeAll()
        log("[QUEUE] dropped \(dropped.count) queued command(s)")
        for c in dropped { c.completion?("CANCELLED") }
    }

    func sendRaw(_ data: String) {
        writeToTransport((data + "\r").data(using: .ascii)!)
        log("[TX] \(data)")
    }

    func startBluetoothScan() {
        discoveredDevices.removeAll()
        if centralManager == nil { centralManager = CBCentralManager(delegate: self, queue: .main) }
        else if centralManager?.state == .poweredOn {
            updateState(.scanning)
            centralManager?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                self?.centralManager?.stopScan()
                if self?.state == .scanning { self?.updateState(.disconnected) }
            }
        }
    }

    func stopBluetoothScan() {
        centralManager?.stopScan()
        if state == .scanning { updateState(.disconnected) }
    }

    func connectToDevice(id: String) {
        guard let cm = centralManager, let uuid = UUID(uuidString: id) else { return }
        if let p = cm.retrievePeripherals(withIdentifiers: [uuid]).first {
            connectedPeripheral = p; p.delegate = self
            updateState(.connecting); cm.connect(p, options: nil)
        }
    }

    // MARK: - Transport

    private func writeToTransport(_ data: Data) {
        switch transport {
        case .wifi:
            tcpConnection?.send(content: data, completion: .contentProcessed({ _ in }))
        case .bluetooth:
            guard let c = writeCharacteristic, let p = connectedPeripheral else { return }
            let type: CBCharacteristicWriteType = c.properties.contains(.write) ? .withResponse : .withoutResponse
            let mtu = max(1, p.maximumWriteValueLength(for: type))
            var off = 0
            while off < data.count {
                let chunk = data.subdata(in: off..<min(off+mtu, data.count))
                p.writeValue(chunk, for: c, type: type)
                off += mtu
            }
        }
    }

    // MARK: - WiFi

    private func connectWiFi() {
        updateState(.connecting)
        tcpConnection = NWConnection(host: NWEndpoint.Host(wifiHost),
                                     port: NWEndpoint.Port(rawValue: wifiPort)!, using: .tcp)
        tcpConnection?.stateUpdateHandler = { [weak self] s in
            DispatchQueue.main.async {
                switch s {
                case .ready:
                    self?.log("TCP connected"); self?.updateState(.ready); self?.startReceiving()
                case .failed(let e):
                    self?.log("TCP failed: \(e)"); self?.updateState(.error)
                case .cancelled:
                    self?.updateState(.disconnected)
                default: break
                }
            }
        }
        tcpConnection?.start(queue: .main)
    }

    private func startReceiving() {
        tcpConnection?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, err in
            if let data = data, !data.isEmpty { self?.handleReceivedData(data) }
            if done || err != nil { DispatchQueue.main.async { self?.updateState(.disconnected) }; return }
            self?.startReceiving()
        }
    }

    private func connectBluetooth() {
        if centralManager == nil { centralManager = CBCentralManager(delegate: self, queue: .main) }
        startBluetoothScan()
    }

    // MARK: - Command Queue

    private func processNextCommand() {
        guard !isProcessingCommand, !commandQueue.isEmpty, state == .ready || state == .busy else { return }
        isProcessingCommand = true
        let cmd = commandQueue.removeFirst()
        currentCommand = cmd; responseBuffer = ""
        let up = cmd.command.uppercased().replacingOccurrences(of: " ", with: "")
        if up.hasPrefix("ATSP") { isJ1850 = (up == "ATSP2") }
        else if up.hasPrefix("ATZ") { isJ1850 = false }
        writeToTransport((cmd.command + "\r").data(using: .ascii)!)
        log("[TX] \(cmd.command)")
        commandTimer?.invalidate()
        commandTimer = Timer.scheduledTimer(withTimeInterval: cmd.timeout, repeats: false) { [weak self] _ in
            let c = self?.currentCommand
            self?.log("[TIMEOUT] \(c?.command ?? "")")
            self?.currentCommand = nil; self?.isProcessingCommand = false
            c?.completion?("TIMEOUT"); self?.processNextCommand()
        }
    }

    // MARK: - Response Parsing

    private func handleReceivedData(_ data: Data) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.onRawData?(data)
            self.log("[RAW RX] " + data.map { String(format: "%02X", $0) }.joined(separator: " "))
            // ISO Latin-1 never fails: the real adapter (and the emulator) put a
            // 0xFC byte in the ATZ reply ("ATZ\r\xFC\r\r OBDII v1.5"), and a
            // strict ASCII decode dropped the whole chunk -> ATZ TIMEOUT.
            guard let str = String(data: data, encoding: .isoLatin1) else { return }
            self.responseBuffer += str
            guard self.responseBuffer.contains(">") else { return }

            let full = self.responseBuffer; self.responseBuffer = ""
            self.commandTimer?.invalidate()
            let parsed = self.parseResponse(full)
            self.log("[RX] \(parsed)")

            // NRC 0x21 retry (busyRepeatRequest) — up to 3 times.
            // Token match: real responses carry 7F/21 as plain data bytes too
            // (e.g. "09 7F 03 A1" inside block 0x12, or block "61 21 ...").
            if Self.hasNRC(parsed, code: 0x21) {
                if let cmd = self.currentCommand, cmd.retryCount < 3 {
                    self.log("[RETRY] NRC 0x21, attempt \(cmd.retryCount + 1)")
                    var retry = cmd; retry = ELMCommand(cmd.command, timeout: cmd.timeout,
                                                         retryCount: cmd.retryCount + 1, completion: cmd.completion)
                    self.currentCommand = nil; self.isProcessingCommand = false
                    self.commandQueue.insert(retry, at: 0)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.processNextCommand() }
                    return
                }
            }

            let cmd = self.currentCommand
            self.currentCommand = nil; self.isProcessingCommand = false
            self.onResponse?(parsed)
            cmd?.completion?(parsed); self.processNextCommand()
        }
    }

    private func parseResponse(_ raw: String) -> String {
        var lines = raw.replacingOccurrences(of: ">", with: "")
            .replacingOccurrences(of: "\r\n", with: "\r")
            .components(separatedBy: "\r")
            .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\u{FC}", with: "") }
            .filter { !$0.isEmpty }

        // Strip echo
        if let cmd = currentCommand?.command.uppercased(), let first = lines.first?.uppercased(),
           first.hasPrefix(cmd.prefix(min(4, cmd.count))) || first == cmd {
            lines.removeFirst()
        }

        // Filter unsolicited bus traffic. Real captures (pcap/full_modules.pcap)
        // show "2D 28 ..", "2D 58 ..", "B8 58 02 2B" and "23 A0 00 18 7C" frames
        // interleaved with responses. On J1850 with ATH1 every genuine reply
        // to us starts with "26 <addr>", so keep only those hex lines (plus
        // non-hex text such as NO DATA / OK / BUS INIT).
        lines = lines.filter { line in
            let up = line.uppercased()
            if up.hasPrefix("2D ") || up.hasPrefix("2D28") { return false }
            guard isJ1850 else { return true }
            let isHexLine = up.count >= 2 && up.prefix(2).allSatisfy { $0.isHexDigit }
                && (up.count == 2 || up[up.index(up.startIndex, offsetBy: 2)] == " ")
            return !isHexLine || up.hasPrefix("26 ")
        }

        return lines.joined(separator: "\r")
    }

    // MARK: - Helpers

    private func updateState(_ s: ConnectionState) {
        DispatchQueue.main.async { self.state = s; self.log("[STATE] \(s.rawValue)") }
    }

    func log(_ msg: String) {
        DispatchQueue.main.async {
            let ts = Self.tsf.string(from: Date())
            self.logMessages.append("[\(ts)] \(msg)")
            if self.logMessages.count > 500 { self.logMessages.removeFirst(self.logMessages.count - 500) }
        }
    }
    private static let tsf: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()
}

// MARK: - CBCentralManagerDelegate
extension ELM327Connection: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        if c.state == .poweredOn && (state == .scanning || state == .connecting) {
            c.scanForPeripherals(withServices: nil, options: nil)
        }
    }
    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String:Any], rssi: NSNumber) {
        let name = p.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "Unknown"
        let id = p.identifier.uuidString
        bleRSSI = rssi.intValue
        if !discoveredDevices.contains(where: { $0.id == id }) && name != "Unknown" {
            discoveredDevices.append((name: name, id: id))
        }
    }
    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        c.stopScan(); bleReport.removeAll(); allCharacteristics.removeAll()
        txCandidates.removeAll(); rxCandidates.removeAll()
        bleReport.append("BLE CONNECT \(p.name ?? "Unknown")"); p.discoverServices(nil)
    }
    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) { updateState(.error) }
    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        cancelQueuedCommands(); commandTimer?.invalidate()
        currentCommand?.completion?("BLE DISCONNECTED"); currentCommand = nil
        isProcessingCommand = false; responseBuffer = ""
        connectedPeripheral = nil; writeCharacteristic = nil; notifyCharacteristic = nil
        log("BLE DISCONNECT \(error?.localizedDescription ?? "")"); updateState(.disconnected)
    }
}

// MARK: - CBPeripheralDelegate
extension ELM327Connection: CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { log("GATT services: \(error.localizedDescription)"); updateState(.error); return }
        p.services?.forEach { bleReport.append("Service \($0.uuid.uuidString)"); p.discoverCharacteristics(nil, for: $0) }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        if let error { log("GATT characteristics: \(error.localizedDescription)"); return }
        s.characteristics?.forEach { c in
            allCharacteristics.append(c)
            if c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse) { txCandidates.append(c.uuid.uuidString) }
            if c.properties.contains(.notify) || c.properties.contains(.indicate) { rxCandidates.append(c.uuid.uuidString) }
            let properties = [c.properties.contains(.write) ? "Write" : nil,
                              c.properties.contains(.writeWithoutResponse) ? "WriteWithoutResponse" : nil,
                              c.properties.contains(.notify) ? "Notify" : nil,
                              c.properties.contains(.indicate) ? "Indicate" : nil,
                              c.properties.contains(.read) ? "Read" : nil].compactMap { $0 }.joined(separator: ", ")
            bleReport.append("\(s.uuid.uuidString) / \(c.uuid.uuidString): \(properties)")
        }
        let id = p.identifier.uuidString
        if let tx = UserDefaults.standard.string(forKey: "tx.\(id)") { selectTX(tx) }
        if let rx = UserDefaults.standard.string(forKey: "rx.\(id)") { selectRX(rx) }
        if writeCharacteristic == nil, let tx = allCharacteristics.first(where: { $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse) }) { selectTX(tx.uuid.uuidString) }
        if notifyCharacteristic == nil, let rx = allCharacteristics.first(where: { $0.properties.contains(.notify) || $0.properties.contains(.indicate) }) { selectRX(rx.uuid.uuidString) }
        if writeCharacteristic != nil && notifyCharacteristic == nil { log("GATT RX characteristic not found"); updateState(.error) }
    }
    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        log("GATT notify \(c.uuid.uuidString): \(error?.localizedDescription ?? String(c.isNotifying))")
        if c.isNotifying && writeCharacteristic != nil { updateState(.ready) }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        if let d = c.value { handleReceivedData(d) }
    }
}
