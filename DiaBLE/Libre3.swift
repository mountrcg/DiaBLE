import Foundation


// https://insulinclub.de/index.php?thread/33795-free-three-ein-xposed-lsposed-modul-f%C3%BCr-libre-3-aktueller-wert-am-sperrbildschir/&postID=655055#post655055

extension String {
    /// Converts a LibreView account ID string into a receiverID
    var fnv32Hash: UInt32 { UInt32(self.reduce(0) { 0xFFFFFFFF & (UInt64($0) * 0x811C9DC5) ^ UInt64($1.asciiValue!) }) }
}


class Libre3: Sensor {


    enum State: UInt8, CustomStringConvertible {
        case manufacturing      = 0

        /// out of package, not activated yet
        case storage            = 1

        case insertionDetection = 2
        case insertionFailed    = 3

        /// advertising via BLE already 10/15 minutes after activation
        case paired             = 4

        /// if Trident is not run on the 15th day, still advertising further than 12 hours, almost 24
        case expired            = 5

        /// Trident sent the shutdown command as soon as run on the 15th day or
        /// the sensor stopped advertising via BLE by itself on the 16th day anyway
        case terminated         = 6

        /// detected for a sensor that fell off
        case error              = 7

        case errorTerminated    = 8

        var description: String {
            switch self {
            case .manufacturing:      return "Manufacturing"
            case .storage:            return "Not activated"
            case .insertionDetection: return "Insertion detection"
            case .insertionFailed:    return "Insertion failed"
            case .paired:             return "Paired"
            case .expired:            return "Expired"
            case .terminated:         return "Terminated"
            case .error:              return "Error"
            case .errorTerminated:    return "Terminated (error)"
            }
        }
    }


    enum LifeState: Int, CustomStringConvertible {
        case missing         = 1
        case warmup          = 2
        case ready           = 3
        case expired         = 4
        case active          = 5
        case ended           = 6
        case insertionFailed = 7

        var description: String {
            switch self {
            case .missing:         return "missing"
            case .warmup:          return "warmup"
            case .ready:           return "ready"
            case .expired:         return "expired"
            case .active:          return "active"
            case .ended:           return "ended"
            case .insertionFailed: return "insertion failed"
            }
        }
    }


    enum Condition: Int, CustomStringConvertible {
        case ok      = 0
        case invalid = 1

        /// Early Signal Attenuation
        case esa     = 2

        var description: String {
            switch self {
            case .ok:      return "OK"
            case .invalid: return "invalid"
            case .esa:     return "ESA"
            }
        }
    }


    enum ProductType: Int, CustomStringConvertible {
        case others = 1
        case sensor = 4

        var description: String {
            switch self {
            case .others: return "OTHERS"
            case .sensor: return "SENSOR"
            }
        }
    }


    enum ResultRange: Int, CustomStringConvertible {
        case `in`  = 0
        case below = 1
        case above = 2

        var description: String {
            switch self {
            case .in:    return "in range"
            case .below: return "below range"
            case .above: return "above range"
            }
        }
    }


    // TODO: var members, struct references, enums


    struct PatchInfo {
        let NFC_Key: Int
        let localization: Int  // 1: Europe, 2: US
        let generation: Int
        let wearDuration: Int
        let warmupTime: Int
        let productType: ProductType
        let state: State
        let fwVersion: Data
        let compressedSN: Data
        let securityVersion: Int
    }


    struct ErrorData {
        let errorCode: Int
        let data: Data
    }


    struct GlucoseData {
        let lifeCount: UInt16
        let readingMgDl: UInt16
        let dqError: UInt16
        let historicalLifeCount: UInt16
        let historicalReading: UInt16
        let projectedGlucose: UInt16
        let historicalReadingDQError: UInt16
        let rateOfChange: UInt16
        let trend: OOP.TrendArrow
        let esaDuration: UInt16
        let temperatureStatus: Int
        let actionableStatus: Int
        let glycemicAlarmStatus: OOP.Alarm
        let glucoseRangeStatus: ResultRange
        let sensorCondition: Condition
        let uncappedCurrentMgDl: Int
        let uncappedHistoricMgDl: Int
        let temperature: Int
        let fastData: Data
    }


    struct HistoricalData {
        let reading: Int
        let dqError: Int
        let lifeCount: Int
    }


    struct ActivationResponse {
        let bdAddress: Data         // 6 bytes
        let BLE_Pin: Data           // 4 bytes
        let activationTime: UInt32  // 4 bytes
    }


    struct EventLog {
        let lifeCount: Int
        let errorData: Int
        let eventData: Int
        let index: UInt8
    }


    struct FastData {
        let lifeCount: Int
        let uncappedReadingMgdl: Int
        let uncappedHistoricReadingMgDl: Int
        let dqError: Int
        let temperature: Int
        let rawData: Data
    }


    struct PatchStatus {
        let patchState: State
        let totalEvents: Int
        let lifeCount: Int
        let errorData: Int
        let eventData: Int
        let index: UInt8
        let currentLifeCount: Int
        let stackDisconnectReason: UInt8
        let appDisconnectReason: UInt8
    }


    struct InitParam {
        let activationTime: UInt32
        var firstConnect: Bool
        let serialNumber: String
        var lastLifeCountReceived: Int
        let hybridModeEnabled: Bool
        let dataFile: Any
        let blePIN: Data
        var lastEventReceived: Int
        let deviceAddress: Data
        let warmupDuration: Int
        let wearDuration: Int
        var lastHistoricLifeCountReceived: Int
        let exportedKAuth: Data
        let securityVersion: Int
    }


    enum PacketType: UInt8 {
        case controlCommand   = 0
        case controlResponse  = 1
        case patchStatus      = 2
        case currentGlucose   = 3
        case backfillHistoric = 4
        case backfillClinical = 5
        case eventLog         = 6
        case factoryData      = 7
    }

    static let packetDescriptors: [[UInt8]] = [
        [0x00, 0x00, 0x00],
        [0x00, 0x00, 0x0F],
        [0x00, 0x00, 0xF0],
        [0x00, 0x0F, 0x00],
        [0x00, 0xF0, 0x00],
        [0x0F, 0x00, 0x00],
        [0xF0, 0x00, 0x00],
        [0x44, 0x00, 0x00]
    ]


    struct BCSecurityContext {
        let packetDescriptorArray: [[UInt8]] = packetDescriptors
        var key: Data    = Data(count: 16)
        var iv_enc: Data = Data(count: 8)
        var nonce: Data  = Data(count: 13)
        var outCryptoSequence: UInt16 = 0

        // when decrypting initialize:
        // nonce[0...1]: outCryptoSequence
        // nonce[2...4]: packetDesciptors(packetType)
        // nonce[5...12]: iv_enc
        // taglen = 4
    }


    struct CGMSensor {
        var sensor: Sensor
        var deviceType: Int
        var cryptoLib: Any
        var securityContext: BCSecurityContext
        var patchEphemeral: Data
        var r1: Data
        var r2: Data
        var nonce1: Data
        var kEnc: Data
        var ivEnc: Data
        var exportedkAuth: Data
        var securityLibInitialized: Bool
        var isPreAuthorized: Bool
        var initParam: InitParam
        var securityVersion: Int
    }


    enum UUID: String, CustomStringConvertible, CaseIterable {

        case data             = "089810CC-EF89-11E9-81B4-2A2AE2DBCCE4"
        case patchControl     = "08981338-EF89-11E9-81B4-2A2AE2DBCCE4"
        case patchStatus      = "08981482-EF89-11E9-81B4-2A2AE2DBCCE4"
        case oneMinuteReading = "0898177A-EF89-11E9-81B4-2A2AE2DBCCE4"
        case historicalData   = "0898195A-EF89-11E9-81B4-2A2AE2DBCCE4"
        case clinicalData     = "08981AB8-EF89-11E9-81B4-2A2AE2DBCCE4"
        case eventLog         = "08981BEE-EF89-11E9-81B4-2A2AE2DBCCE4"
        case factoryData      = "08981D24-EF89-11E9-81B4-2A2AE2DBCCE4"

        case security         = "0898203A-EF89-11E9-81B4-2A2AE2DBCCE4"
        case securityCommands = "08982198-EF89-11E9-81B4-2A2AE2DBCCE4"
        case challengeData    = "089822CE-EF89-11E9-81B4-2A2AE2DBCCE4"
        case certificateData  = "089823FA-EF89-11E9-81B4-2A2AE2DBCCE4"

        case debug            = "08982400-EF89-11E9-81B4-2A2AE2DBCCE4"
        case bleLogin         = "F001"

        var description: String {
            switch self {
            case .data:             return "data service"
            case .patchControl:     return "patch control"
            case .patchStatus:      return "patch status"
            case .oneMinuteReading: return "one-minute reading"
            case .historicalData:   return "historical data"
            case .clinicalData:     return "clinical data"
            case .eventLog:         return "event log"
            case .factoryData:      return "factory data"
            case .security:         return "security service"
            case .securityCommands: return "security commands"
            case .challengeData:    return "challenge data"
            case .certificateData:  return "certificate data"
            case .debug:            return "debug service"
            case .bleLogin:         return "BLE login"
            }
        }
    }

    class var knownUUIDs: [String] { UUID.allCases.map(\.rawValue) }


    // - maximum packet size is 20
    // - notified packets are prefixed by 00, 01, 02, ...
    // - written packets are prefixed by 00 00, 12 00, 24 00, 36 00, ...
    // - data packets end in a sequential Int: 01 00, 02 00, ...
    //
    // Connection:
    // enable notifications for 2198, 23FA and 22CE
    // write  2198  11
    // notify 2198  08 17
    // notify 22CE  20 + 5 bytes        // 23-byte challenge
    // write  22CE  20 + 20 + 6 bytes   // 40-byte challenge response
    // write  2198  08
    // notify 2198  08 43
    // notify 22CE  20 * 3 + 11 bytes   // 67-byte session info (wrapped kAuth?)
    // enable notifications for 1338, 1BEE, 195A, 1AB8, 1D24, 1482
    // notify 1482  18-byte packets     // patch status
    // enable notifications for 177A
    // write  1338  13 bytes            // command ending in 01 00
    // notify 177A  15 + 20 bytes       // one-minute reading
    // notify 195A  20-byte packets     // historical data
    // notify 1338  10 bytes            // ending in 01 00
    // write  1338  13 bytes            // command ending in 02 00
    // notify 1AB8  20-byte packets     // clinical data
    // notify 1338  10 bytes            // ending in 02 00
    //
    // Activation:
    // enable notifications for 2198, 23FA and 22CE
    // write  2198  01
    // write  2198  02
    // write  23FA  20 * 9 bytes        // 162-byte fixed certificate data
    // write  2198  03
    // notify 2198  04                  // certificate accepted event
    // write  2198  09
    // notify 2198  0A 8C               // certificate ready event
    // notify 23FA  20 * 7 + 8 bytes    // 140-byte payload
    // write  2198  0D
    // write  23FA  20 * 3 + 13 bytes   // 65-byte payload
    // write  2198  0E
    // notify 2198  0F 41               // ephemeral ready event
    // notify 23FA  20 * 3 + 9 bytes    // 65-byte paylod
    // write  2198  11
    // notify 2198  08 17
    // notify 22CE  20 + 5 bytes        // 23-byte challenge
    // write  22CE  20 * 2 + 6 bytes    // 40-byte challenge response
    // write  2198  08
    // notify 2198  08 43
    // notify 22CE  20 * 3 + 11 bytes   // 67-byte session info (wrapped kAuth?)
    // enable notifications for 1338, 1BEE, 195A, 1AB8, 1D24, 1482
    // notify 1482  18 bytes            // patch status
    // enable notifications for 177A
    // write  1338  13 bytes            // command ending in 01 00
    // notify 1BEE  20 + 20 bytes       // event log
    // notify 1338  10 bytes            // ending in 01 00
    // write  1338  13 bytes            // command ending in 02 00
    // notify 1D24  20 * 10 + 17 bytes  // 195-byte factory data
    // notify 1338  10 bytes            // ending in 02 00
    //
    // Shutdown:
    // write  1338  13 bytes            // command ending in 03 00
    // notify 1BEE  20 bytes            // event log
    // notify 1338  10 bytes            // ending in 03 00
    // write  1338  13 bytes            // command ending in 04 00


    enum SecurityCommand: UInt8, CustomStringConvertible {

        case security_01    = 0x01
        case security_02    = 0x02
        case security_03    = 0x03
        case security_09    = 0x09
        case security_0D    = 0x0D
        case security_0E    = 0x0E
        case getSessionInfo = 0x08
        case readChallenge  = 0x11

        var description: String {
            switch self {
            case .security_01:    return "security 0x01 command"
            case .security_02:    return "security 0x02 command"
            case .security_03:    return "security 0x03 command"
            case .security_09:    return "security 0x09 command"
            case .security_0D:    return "security 0x0D command"
            case .security_0E:    return "security 0x0E command"
            case .getSessionInfo: return "get session info"
            case .readChallenge:  return "read security challenge"
            }
        }
    }

    enum SecurityEvent: UInt8, CustomStringConvertible {

        case unknown             = 0x00
        case certificateAccepted = 0x04
        case challengeLoadDone   = 0x08
        case certificateReady    = 0x0A
        case ephemeralReady      = 0x0F

        var description: String {
            switch self {
            case .unknown:             return "unknown [TODO]"
            case .certificateAccepted: return "certificate accepted"
            case .challengeLoadDone:   return "challenge load done"
            case .certificateReady:    return "certificate ready"
            case .ephemeralReady:      return "ephemeral ready"
            }
        }
    }

    /// 13 bytes written to .patchControl:
    /// - PATCH_CONTROL_COMMAND_SIZE = 7
    /// - a final sequential Int starting by 01 00 since it is enqueued
    enum ControlCommand {
        /// - 010001 EC2C 0000 requests historical data from lifeCount 11520 (0x2CEC)
        case historic(Data)       // type 1

        /// Requests past clinical data
        /// - 010101 9B48 0000 requests clinical data from lifeCount 18587 (0x489B)
        case backfill(Data)       // type 2

        /// - 040100 0000 0000
        case eventLog(Data)       // type 3

        /// - 060000 0000 0000
        case factoryData(Data)    // type 4

        case shutdownPatch(Data)  // type 5
    }

    var receiverId: UInt32 = 0    // fnv32Hash of LibreView ID string

    var blePIN: Data = Data()    // 4 bytes returned by the activation command

    var buffer: Data = Data()
    var currentControlCommand:  ControlCommand?
    var currentSecurityCommand: SecurityCommand?
    var lastSecurityEvent: SecurityEvent = .unknown
    var expectedStreamSize = 0

    var outCryptoSequence: UInt16 = 0


    func parsePatchInfo() {

        let securityVersion = UInt16(patchInfo[0...1])
        let localization    = UInt16(patchInfo[2...3])
        let generation      = UInt16(patchInfo[4...5])
        log("Libre 3: security version: \(securityVersion) (0x\(securityVersion.hex)), localization: \(localization) (0x\(localization.hex)), generation: \(generation) (0x\(generation.hex))")

        region = SensorRegion(rawValue: Int(localization)) ?? .unknown

        let wearDuration = patchInfo[6...7]
        maxLife = Int(UInt16(wearDuration))
        log("Libre 3: wear duration: \(maxLife) minutes (\(maxLife.formattedInterval), 0x\(maxLife.hex))")

        let fwVersion = patchInfo.subdata(in: 8 ..< 12)
        firmware = "\(fwVersion[3]).\(fwVersion[2]).\(fwVersion[1]).\(fwVersion[0])"
        log("Libre 3: firmware version: \(firmware)")

        let productType = Int(patchInfo[12])  // 04 = SENSOR
        log("Libre 3: product type: \(ProductType(rawValue: productType)?.description ?? "unknown") (0x\(productType.hex))")

        // TODO: verify
        let warmupTime = patchInfo[13]
        log("Libre 3: warmup time: \(warmupTime * 5) minutes (0x\(warmupTime.hex) * 5?)")

        let sensorState = patchInfo[14]
        // TODO: manage specific Libre 3 states
        state = SensorState(rawValue: sensorState <= 2 ? sensorState: sensorState - 1) ?? .unknown
        log("Libre 3: specific state: \(State(rawValue: sensorState)!.description.lowercased()) (0x\(sensorState.hex)), state: \(state.description.lowercased()) ")

        let serialNumber = Data(patchInfo[15...23])
        serial = serialNumber.string
        log("Libre 3: serial number: \(serial) (0x\(serialNumber.hex))")

    }


    func send(securityCommand cmd: SecurityCommand) {
        log("Bluetooth: sending to \(type) \(transmitter!.peripheral!.name ?? "(unnamed)") `\(cmd.description)` command 0x\(cmd.rawValue.hex)")
        currentSecurityCommand = cmd
        transmitter!.write(Data([cmd.rawValue]), for: UUID.securityCommands.rawValue, .withResponse)
    }


    func parsePackets(_ data: Data) -> (Data, String) {
        var payload = Data()
        var str = ""
        var offset = data.startIndex
        var offsetEnd = offset
        let endIndex = data.endIndex
        while offset < endIndex {
            str += data[offset].hex + "  "
            _ = data.formIndex(&offsetEnd, offsetBy: 20, limitedBy: endIndex)
            str += data[offset + 1 ..< offsetEnd].hexBytes
            payload += data[offset + 1 ..< offsetEnd]
            _ = data.formIndex(&offset, offsetBy: 20, limitedBy: endIndex)
            if offset < endIndex { str += "\n" }
        }
        return (payload, str)
    }


    func write(_ data: Data, for uuid: UUID = .challengeData) {
        let packets = (data.count - 1) / 18 + 1
        for i in 0 ... packets - 1 {
            let offset = i * 18
            let id = Data([UInt8(offset & 0xFF), UInt8(offset >> 8)])
            let packet = id + data[offset ... min(offset + 17, data.count - 1)]
            debugLog("Bluetooth: writing packet \(packet.hexBytes) to \(transmitter!.peripheral!.name!)'s \(uuid.description) characteristic")
            transmitter!.write(packet, for: uuid.rawValue, .withResponse)
        }
    }


    /// called by Abbott Transmitter class
    func read(_ data: Data, for uuid: String) {

        switch UUID(rawValue: uuid) {

        case .patchControl:
            if data.count == 10 {
                let suffix = data.suffix(2).hex
                // TODO: manage enqueued id
                if buffer.count % 20 == 0 {
                    if suffix == "0100" {
                        log("\(type) \(transmitter!.peripheral!.name!): received \(buffer.count/20) packets of historical data")
                        // TODO
                    } else if suffix == "0200" {
                        log("\(type) \(transmitter!.peripheral!.name!): received \(buffer.count/20) packets of clinical data")
                        // TODO
                    }
                } else {
                    var packets = [Data]()
                    for i in 0 ..< (buffer.count + 19) / 20 {
                        packets.append(Data(buffer[i * 20 ... min(i * 20 + 17, buffer.count - 3)]))
                    }
                    if buffer.count == 217 {
                        log("\(type) \(transmitter!.peripheral!.name!): received \(packets.count) packets of factory data, payload: \(Data(packets.joined()).hexBytes)")
                    }
                }
                buffer = Data()
                currentControlCommand = nil
            }

            // The Libre 3 sends every minute 35 bytes as two packets of 15 + 20 bytes
            // The final Int is a sequential id
        case .oneMinuteReading:
            if buffer.count == 0 {
                buffer = Data(data)
            } else {
                buffer += data
                if buffer.count == 35 {
                    let payload = buffer.prefix(33)
                    let id = UInt16(buffer.suffix(2))
                    log("\(type) \(transmitter!.peripheral!.name!): received \(buffer.count) bytes of \(UUID(rawValue: uuid)!) (payload: \(payload.count) bytes): \(payload.hex), id: \(id.hex)")
                    buffer = Data()
                }
            }

        case .historicalData, .clinicalData, .eventLog, .factoryData:
            if buffer.count == 0 {
                buffer = Data(data)
            } else {
                buffer += data
            }
            let payload = data.prefix(18)
            let id = UInt16(data.suffix(2))
            log("\(type) \(transmitter!.peripheral!.name!): received \(data.count) bytes of \(UUID(rawValue: uuid)!) (payload: \(payload.count) bytes): \(payload.hex), id: \(id.hex)")

        case .patchStatus:
            if buffer.count == 0 {
                let payload = data.prefix(16)
                let id = UInt16(data.suffix(2))
                log("\(type) \(transmitter!.peripheral!.name!): received \(data.count) bytes of \(UUID(rawValue: uuid)!) (payload: \(payload.count) bytes): \(payload.hex), id: \(id.hex)")
            }
            // TODO


        case .securityCommands:
            lastSecurityEvent = SecurityEvent(rawValue: data[0]) ?? .unknown
            log("\(type) \(transmitter!.peripheral!.name!): security event: \(lastSecurityEvent)\(lastSecurityEvent == .unknown ? " (" + data[0].hex + ")" : "")")
            if data.count == 2 {
                expectedStreamSize = Int(data[1] + data[1] / 20 + 1)
                log("\(type) \(transmitter!.peripheral!.name!): expected response size: \(expectedStreamSize) bytes (payload: \(data[1]) bytes)")
                // TEST: when sniffing Trident:
                if data[1] == 23 {
                    currentSecurityCommand = .readChallenge
                } else if data[1] == 67 {
                    currentSecurityCommand = .getSessionInfo
                } else if data[1] == 140 { // patchCertificate
                    currentSecurityCommand = .security_09
                } else if data[1] == 65 { // patchEphemeral
                    currentSecurityCommand = .security_0E
                }
            }
            if currentSecurityCommand == .security_03 && lastSecurityEvent == .certificateAccepted {
                send(securityCommand: .security_09)
            }


        case .challengeData, .certificateData:
            if buffer.count == 0 {
                buffer = Data(data)
            } else {
                buffer += data
            }

            if buffer.count == expectedStreamSize {

                let (payload, hexDump) = parsePackets(buffer)
                log("\(type) \(transmitter!.peripheral!.name!): received \(buffer.count) bytes of \(UUID(rawValue: uuid)!) (payload: \(payload.count) bytes):\n\(hexDump)")

                switch currentSecurityCommand {

                case .security_09:
                    log("\(type) \(transmitter!.peripheral!.name!): patch certificate: \(payload.hex)")
                    send(securityCommand: .security_0D)
                    // TODO

                case .security_0E:
                    log("\(type) \(transmitter!.peripheral!.name!): patch ephemeral: \(payload.hex)")
                    send(securityCommand: .readChallenge)
                    // TODO

                case .readChallenge:

                    // getting: df4bd2f783178e3ab918183e5fed2b2b c201 0000 e703a7
                    //                                        increasing

                    outCryptoSequence = UInt16(payload[16...17])
                    log("\(type) \(transmitter!.peripheral!.name!): security challenge: \(payload.hex) (crypto sequence #: \(outCryptoSequence.hex))")

                    let r1 = payload.prefix(16)
                    let nonce1 = payload.suffix(7)
                    let r2 = Data((0 ..< 16).map { _ in UInt8.random(in: UInt8.min ... UInt8.max) })
                    debugLog("\(type): r1: \(r1.hex), r2: \(r2.hex), nonce1: \(nonce1.hex)")

                    // TODO:
                    // let response = process2(command: 7, nonce1, Data(r1 + r2 + blePIN))

                    if main.settings.userLevel < .test { // TEST: sniff Trident
                        log("\(type) \(transmitter!.peripheral!.name!): writing 40-zero challenge response")

                        let challengeData = Data(count: 40)
                        write(challengeData)
                        // writing .getSessionInfo makes the Libre 3 disconnect
                        send(securityCommand: .getSessionInfo)
                    }

                case .getSessionInfo:
                    outCryptoSequence = UInt16(payload[60...61])
                    log("\(type) \(transmitter!.peripheral!.name!): session info: \(payload.hex) (crypto sequence #: \(outCryptoSequence.hex))")
                    transmitter!.peripheral?.setNotifyValue(true, for: transmitter!.characteristics[UUID.patchStatus.rawValue]!)
                    log("\(type) \(transmitter!.peripheral!.name!): enabling notifications on the patch status characteristic")
                    currentSecurityCommand = nil


                default:
                    break // currentSecurityCommand
                }

                buffer = Data()
                expectedStreamSize = 0

            }

        default:
            break  // uuid
        }

    }


    func parseCurrentReading(_ data: Data) {  // -> GlucoseData
        // TODO
        // 062DEE00FCFF0000945CF12CF0000BEE00F000010C530E72482F130000 (29 bytes):
        // 062D: lifeCount 11526 (0x2D06)
        // EE00: readingMgDl 238
        // FCFF: rateOfChange -4 (2**16 - 0xFFFC)
        // 0000: esaDuration
        // 945C: projectedGlucose 23700 (0x5C94)
        // F12C: historicalLifeCount 11505 (0x2CF1)
        // F000: historicalReading 240
        // 0B: 00001 011 (bitfields 3: trend, 5: rest)
        // EE00: uncappedCurrentMgDl 238
        // F000: uncappedHistoricMgDl 240
        // 010C: temperature 3073 (0x0C01)
        // 530E72482F130000: fastData
    }


    // TODO: separate CMD_ACTIVATE_SENSOR and CMD_SWITCH_RECEIVER
    var activationNFCCommand: NFCCommand {
        var parameters: Data = Data()
        parameters += ((activationTime != 0 ? activationTime : UInt32(Date().timeIntervalSince1970)) - 1).data
        parameters += (receiverId != 0 ? receiverId : main.settings.libreLinkUpPatientId.fnv32Hash).data
        parameters += parameters.crc16.data

        // - A8 changes the BLE PIN on an activated sensor and returns the error 0x1B0 on an expired one.
        // - A0 returns the current BLE PIN on an activated sensor, the error 0x1B2 on an expired one with a
        //   firmware like 1.1.13.30 and a new BLE PIN with older firmwares like 1.0.25.30...
        let code = patchInfo[14] == State.storage.rawValue ? 0xA8 : 0xA0

        return NFCCommand(code: code, parameters: parameters, description: "activate")
    }


    func pair() {
        send(securityCommand: .security_01)
        send(securityCommand: .security_02)
        let certificate = "03 00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F 10 00 01 5F 14 9F E1 01 00 00 00 00 00 00 00 00 04 E2 36 95 4F FD 06 A2 25 22 57 FA A7 17 6A D9 0A 69 02 E6 1D DA FF 40 FB 36 B8 FB 52 AA 09 2C 33 A8 02 32 63 2E 94 AF A8 28 86 AE 75 CE F9 22 CD 88 85 CE 8C DA B5 3D AB 2A 4F 23 9B CB 17 C2 6C DE 74 9E A1 6F 75 89 76 04 98 9F DC B3 F0 C7 BC 1D A5 E6 54 1D C3 CE C6 3E 72 0C D9 B3 6A 7B 59 3C FC C5 65 D6 7F 1E E1 84 64 B9 B9 7C CF 06 BE D0 40 C7 BB D5 D2 2F 35 DF DB 44 58 AC 7C 46 15".bytes
        write(certificate, for: .certificateData)
        send(securityCommand: .security_03)
        // TODO
    }

}
