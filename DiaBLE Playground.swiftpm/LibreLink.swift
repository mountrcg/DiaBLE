import Foundation


// https://github.com/timoschlueter/nightscout-librelink-up
// https://gist.github.com/khskekec/6c13ba01b10d3018d816706a32ae8ab2


enum LibreLinkUpError: LocalizedError {
    case noConnection
    case notAuthenticated
    case jsonDecoding

    var errorDescription: String? {
        switch self {
        case .noConnection:     return "no connection"
        case .notAuthenticated: return "not authenticated"
        case .jsonDecoding:     return "JSON decoding"
        }
    }
}


struct AuthTicket: Codable {
    let token: String
    let expires: Int
    let duration: UInt64
}


enum MeasurementColor: Int, Codable {
    case green  = 1
    case yellow = 2
    case orange = 3
    case red    = 4
}


struct GlucoseMeasurement: Codable {
    let factoryTimestamp: String
    let timestamp: String
    let type: Int  //  0: graph, 1: logbook, 2: alarm, 3: hybrid
    let alarmType: Int?  // when type = 3  0: fixedLow, 1: low, 2: high
    let valueInMgPerDl: Int
    let trendArrow: OOP.TrendArrow?    // in logbook but not in graph data
    let trendMessage: String?
    let measurementColor: MeasurementColor
    let glucoseUnits: Int
    let value: Int
    let isHigh: Bool
    let isLow: Bool
    enum CodingKeys: String, CodingKey { case factoryTimestamp = "FactoryTimestamp", timestamp = "Timestamp", type, alarmType, valueInMgPerDl = "ValueInMgPerDl", trendArrow = "TrendArrow", trendMessage = "TrendMessage", measurementColor = "MeasurementColor", glucoseUnits = "GlucoseUnits", value = "Value", isHigh, isLow }
}


struct LibreLinkUpGlucose: Identifiable, Codable {
    let glucose: Glucose
    let color: MeasurementColor
    let trendArrow: OOP.TrendArrow?
    var id: Int { glucose.id }
}


struct LibreLinkUpAlarm: Identifiable, Codable, CustomStringConvertible {
    let factoryTimestamp: String
    let timestamp: String
    let type: Int  // 2 (1 for measurements)
    let alarmType: Int  // 0: low, 1: high, 2: fixedLow
    enum CodingKeys: String, CodingKey { case factoryTimestamp = "FactoryTimestamp", timestamp = "Timestamp", type, alarmType }
    var id: Int { Int(date.timeIntervalSince1970) }
    var date: Date = Date()
    var alarmDescription: String { alarmType == 1 ? "HIGH" : "LOW" }
    var description: String { "\(date): \(alarmDescription)" }
}


class LibreLinkUp: Logging {

    var main: MainDelegate!

    let siteURL = "https://api.libreview.io"
    let loginEndpoint = "llu/auth/login"
    let configEndpoint = "llu/config"
    let connectionsEndpoint = "llu/connections"
    let measurementsEndpoint = "lsl/api/measurements"

    let regions = ["us", "eu", "de", "fr", "jp", "ap", "au", "ae"]

    var regionalSiteURL: String { "https://api-\(main.settings.libreLinkUpRegion).libreview.io" }

    let headers = [
        "User-Agent": "Mozilla/5.0",
        "Content-Type": "application/json",
        "product": "llu.ios",
        "version": "4.5.0",
        "Accept-Encoding": "gzip, deflate, br",
        "Connection": "keep-alive",
        "Pragma": "no-cache",
        "Cache-Control": "no-cache",
    ]


    init(main: MainDelegate) {
        self.main = main
    }


    @discardableResult
    func login() async throws -> (Any, URLResponse) {
        var request = URLRequest(url: URL(string: "\(siteURL)/\(loginEndpoint)")!)
        let credentials = await [
            "email": main.settings.libreLinkUpEmail,
            "password": main.settings.libreLinkUpPassword
        ]
        request.httpMethod = "POST"
        for (header, value) in headers {
            request.setValue(value, forHTTPHeaderField: header)
        }
        let jsonData = try? JSONSerialization.data(withJSONObject: credentials)
        request.httpBody = jsonData
        do {
            var redirected = false
        loop: repeat {
            redirected = false
            debugLog("LibreLinkUp: posting to \(request.url!.absoluteString) \(jsonData!.string), headers: \(headers)")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let response = response as? HTTPURLResponse {
                let status = response.statusCode
                debugLog("LibreLinkUp: response data: \(data.string.trimmingCharacters(in: .newlines)), status: \(status)")
                if status == 401 {
                    log("LibreLinkUp: POST not authorized")
                } else {
                    log("LibreLinkUp: POST \((200..<300).contains(status) ? "success" : "error")")
                }
            }
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let status = json["status"] as? Int {
                    if status == 2 || status == 429 || status == 911 {
                        // {"status":2,"error":{"message":"notAuthenticated"}}
                        // {"status":429,"data":{"code":60,"data":{"failures":3,"interval":60,"lockout":300},"message":"locked"}}
                        // {"status":911} when logging in at a stranger regional server
                        throw LibreLinkUpError.notAuthenticated
                    }

                    let data = json["data"] as? [String: Any]

                    // TODO: redirect
                    // {"status":0,"data":{"redirect":true,"region":"fr"}}
                    if let redirect = data?["redirect"] as? Bool,
                       let region = data?["region"] as? String {
                        redirected = redirect
                        DispatchQueue.main.async {
                            self.main.settings.libreLinkUpRegion = region
                        }
                        log("LibreLinkUp: redirecting to \(regionalSiteURL)/\(loginEndpoint) ")
                        request.url = URL(string: "\(regionalSiteURL)/\(loginEndpoint)")!
                        continue loop
                    }

                    if let data = data,
                       let user = data["user"] as? [String: Any],
                       let id = user["id"] as? String,
                       let country = user["country"] as? String,
                       let authTicketDict = data["authTicket"] as? [String: Any],
                       let authTicketData = try? JSONSerialization.data(withJSONObject: authTicketDict),
                       let authTicket = try? JSONDecoder().decode(AuthTicket.self, from: authTicketData) {
                        self.log("LibreLinkUp: user id: \(id), country: \(country), authTicket: \(authTicket), expires on \(Date(timeIntervalSince1970: Double(authTicket.expires)))")
                        DispatchQueue.main.async {
                            self.main.settings.libreLinkUpPatientId = id
                            self.main.settings.libreLinkUpCountry = country
                            self.main.settings.libreLinkUpToken = authTicket.token
                            self.main.settings.libreLinkUpTokenExpirationDate = Date(timeIntervalSince1970: Double(authTicket.expires))
                        }

                        // TODO: determine regional server
                        if await !main.settings.libreLinkUpCountry.isEmpty {

                            // default "de" and "fr" regional servers
                            let defaultRegion = await regions.contains(country.lowercased()) ? country.lowercased() : main.settings.libreLinkUpRegion

                            var request = URLRequest(url: URL(string: "\(siteURL)/\(configEndpoint)/country?country=\(await main.settings.libreLinkUpCountry)")!)
                            for (header, value) in headers {
                                request.setValue(value, forHTTPHeaderField: header)
                            }
                            debugLog("LibreLinkUp: URL request: \(request.url!.absoluteString), headers: \(request.allHTTPHeaderFields!)")
                            let (data, response) = try await URLSession.shared.data(for: request)
                            debugLog("LibreLinkUp: response data: \(data.string.trimmingCharacters(in: .newlines)), status: \((response as! HTTPURLResponse).statusCode)")
                            do {
                                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                                   let data = json["data"] as? [String: Any],
                                   let server = data["lslApi"] as? String {
                                    let regionIndex = server.firstIndex(of: "-")
                                    let region = regionIndex == nil ? defaultRegion : String(server[server.index(regionIndex!, offsetBy: 1) ... server.index(regionIndex!, offsetBy: 2)])
                                    log("LibreLinkUp: regional server: \(server), saved default region: \(region)")
                                    DispatchQueue.main.async {
                                        self.main.settings.libreLinkUpRegion = region
                                    }
                                }
                            } catch {
                                log("LibreLinkUp: error while decoding response: \(error.localizedDescription)")
                                throw LibreLinkUpError.jsonDecoding
                            }
                        }
                    }
                }
                return (data, response)
            }
        } while redirected
            return (Data(), URLResponse())
        } catch LibreLinkUpError.jsonDecoding {
            log("LibreLinkUp: error while decoding response: \(LibreLinkUpError.jsonDecoding.localizedDescription)")
            throw LibreLinkUpError.jsonDecoding
        } catch LibreLinkUpError.notAuthenticated {
            log("LibreLinkUp: error: \(LibreLinkUpError.notAuthenticated.localizedDescription)")
            throw LibreLinkUpError.notAuthenticated
        } catch {
            log("LibreLinkUp: server error: \(error.localizedDescription)")
            throw LibreLinkUpError.noConnection
        }
    }


    /// - Returns: (data, response, history, logbookData, logbookHistory, logbookAlarms)
    func getPatientGraph() async throws -> (Any, URLResponse, [LibreLinkUpGlucose], Any, [LibreLinkUpGlucose], [LibreLinkUpAlarm]) {
        var request = URLRequest(url: URL(string: "\(regionalSiteURL)/\(connectionsEndpoint)/\(await main.settings.libreLinkUpPatientId)/graph")!)
        var authenticatedHeaders = headers
        authenticatedHeaders["Authorization"] = await "Bearer \(main.settings.libreLinkUpToken)"
        for (header, value) in authenticatedHeaders {
            request.setValue(value, forHTTPHeaderField: header)
        }
        debugLog("LibreLinkUp: URL request: \(request.url!.absoluteString), authenticated headers: \(request.allHTTPHeaderFields!)")

        var history: [LibreLinkUpGlucose] = []
        var logbookData: Data = Data()
        var logbookHistory: [LibreLinkUpGlucose] = []
        var logbookAlarms: [LibreLinkUpAlarm] = []

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")  // https://github.com/creepymonster/GlucoseDirect/commit/b84deb7
        dateFormatter.dateFormat = "M/d/yyyy h:mm:ss a"

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as! HTTPURLResponse).statusCode
            debugLog("LibreLinkUp: response data: \(data.string.trimmingCharacters(in: .newlines)), status: \(status)")
            // TODO: {"status":911}: server maintenance
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let data = json["data"] as? [String: Any],
                   let connection = data["connection"] as? [String: Any] {
                    log("LibreLinkUp: connection data: \(connection)")
                    var deviceSerials: [String: String] = [:]
                    var deviceActivationTimes: [String: Int] = [:]
                    var deviceTypes: [String: SensorType] = [:]
                    if let activeSensors = data["activeSensors"] as? [[String: Any]] {
                        log("LibreLinkUp: active sensors: \(activeSensors)")
                        for (i, activeSensor) in activeSensors.enumerated() {
                            if let sensor = activeSensor["sensor"] as? [String: Any],
                               let device = activeSensor["device"] as? [String: Any],
                               let dtid = device["dtid"] as? Int,
                               let v = device["v"] as? String,
                               let alarms = device["alarms"] as? Bool,
                               let deviceId = sensor["deviceId"] as? String,
                               var sn = sensor["sn"] as? String,
                               let a = sensor["a"] as? Int,
                               // pruduct type should be 0: .libre1, 3: .libre2, 4: .libre3 but happening a Libre 1 with `pt` = 3...
                               let pt = sensor["pt"] as? Int {
                                let sensorType: SensorType =
                                dtid == 40068 ? .libre3 :
                                dtid == 40067 ? .libre2 :
                                dtid == 40066 ? .libre1 : .unknown
                                deviceTypes[deviceId] = sensorType
                                // according to bundle.js, if `alarms` is true 40066 is also a .libre2
                                // but happening a Libre 1 with `alarms` = true...
                                if sn.count == 10 {
                                    switch sensorType {
                                    case .libre1: sn = "0" + sn
                                    case .libre2: sn = "3" + sn
                                    case .libre3: sn = String(sn.dropLast()) // trim final 0
                                    default: break
                                    }
                                }
                                deviceSerials[deviceId] = sn
                                if deviceActivationTimes[deviceId] == nil || deviceActivationTimes[deviceId]! > a {
                                    deviceActivationTimes[deviceId] = a
                                }
                                let activationDate = Date(timeIntervalSince1970: Double(a))
                                log("LibreLinkUp: active sensor # \(i + 1) of \(activeSensors.count): serial: \(sn), activation date: \(activationDate) (timestamp = \(a)), LibreLink version: \(v), device id: \(deviceId), product type: \(pt), sensor type: \(sensorType), alarms: \(alarms)")
                            }
                        }
                    }
                    if let device = connection["patientDevice"] as? [String: Any],
                       let deviceId = device["did"] as? String,
                       let alarms = device["alarms"] as? Bool,
                       let serial = deviceSerials[deviceId] {
                        let sensorType = deviceTypes[deviceId]!
                        let activationTime = deviceActivationTimes[deviceId]!
                        let activationDate = Date(timeIntervalSince1970: Double(activationTime))
                        if await main.app.sensor == nil {
                            DispatchQueue.main.async {
                                self.main.app.sensor = sensorType == .libre3 ? Libre3(main: self.main) : sensorType == .libre2 ? Libre2(main: self.main) : Sensor(main: self.main)
                                self.main.app.sensor.type = sensorType
                                self.main.app.sensor.serial = serial
                            }
                        } else {
                            if await self.main.app.sensor.serial.isEmpty {
                                await self.main.app.sensor.serial = serial
                            }
                        }
                        if await main.app.sensor.serial.hasSuffix(serial) || deviceTypes.count == 1 {
                            DispatchQueue.main.async {
                                self.main.app.sensor.activationTime = UInt32(activationTime)
                                self.main.app.sensor.age = Int(Date().timeIntervalSince(activationDate)) / 60
                                self.main.app.sensor.state = .active
                                self.main.app.sensor.lastReadingDate = Date()
                                if self.main.app.sensor.type == .libre3 {
                                    self.main.app.sensor.serial = serial
                                    self.main.app.sensor.maxLife = 20160
                                    let receiverId = self.main.settings.libreLinkUpPatientId.fnv32Hash
                                    (self.main.app.sensor as! Libre3).receiverId = receiverId
                                    self.log("LibreLinkUp: LibreView receiver ID: \(receiverId)")
                                }
                                self.main.status("\(self.main.app.sensor.type)  +  LLU")
                            }
                        }
                        log("LibreLinkUp: sensor serial: \(serial), activation date: \(activationDate) (timestamp = \(activationTime)), device id: \(deviceId), sensor type: \(sensorType), alarms: \(alarms)")
                        if let lastGlucoseMeasurement = connection["glucoseMeasurement"] as? [String: Any],
                           let measurementData = try? JSONSerialization.data(withJSONObject: lastGlucoseMeasurement),
                           let measurement = try? JSONDecoder().decode(GlucoseMeasurement.self, from: measurementData) {
                            let date = dateFormatter.date(from: measurement.timestamp)!
                            let lifeCount = Int(round(date.timeIntervalSince(activationDate) / 60))
                            let lastGlucose = LibreLinkUpGlucose(glucose: Glucose(measurement.valueInMgPerDl, id: lifeCount, date: date, source: "LibreLinkUp"), color: measurement.measurementColor, trendArrow: measurement.trendArrow)
                            debugLog("LibreLinkUp: last glucose measurement: \(measurement) (JSON: \(lastGlucoseMeasurement))")
                            // TODO: scrape historic data only when the 17-minute delay has passed
                            var i = 0
                            if let graphData = data["graphData"] as? [[String: Any]] {
                                for glucoseMeasurement in graphData {
                                    if let measurementData = try? JSONSerialization.data(withJSONObject: glucoseMeasurement),
                                       let measurement = try? JSONDecoder().decode(GlucoseMeasurement.self, from: measurementData) {
                                        i += 1
                                        let date = dateFormatter.date(from: measurement.timestamp)!
                                        var lifeCount = Int(date.timeIntervalSince(activationDate)) / 60
                                        // FIXME: lifeCount not always multiple of 5
                                        if lifeCount % 5 == 1 { lifeCount -= 1 }
                                        history.append(LibreLinkUpGlucose(glucose: Glucose(measurement.valueInMgPerDl, id: lifeCount, date: date, source: "LibreLinkUp"), color: measurement.measurementColor, trendArrow: measurement.trendArrow))
                                        debugLog("LibreLinkUp: graph measurement # \(i) of \(graphData.count): \(measurement) (JSON: \(glucoseMeasurement)), lifeCount = \(lifeCount)")
                                    }
                                }
                            }
                            history.append(lastGlucose)
                            log("LibreLinkUp: graph values: \(history.map { ($0.glucose.id, $0.glucose.value, $0.glucose.date.shortDateTime, $0.color) })")

                            if await main.settings.libreLinkUpScrapingLogbook,
                               let ticketDict = json["ticket"] as? [String: Any],
                               let token = ticketDict["token"] as? String {
                                self.log("LibreLinkUp: new token for logbook: \(token)")
                                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                                request.url =  URL(string: "\(regionalSiteURL)/\(connectionsEndpoint)/\(await main.settings.libreLinkUpPatientId)/logbook")!
                                debugLog("LibreLinkUp: URL request: \(request.url!.absoluteString), authenticated headers: \(request.allHTTPHeaderFields!)")
                                let (data, response) = try await URLSession.shared.data(for: request)
                                debugLog("LibreLinkUp: response data: \(data.string.trimmingCharacters(in: .newlines)), status: \((response as! HTTPURLResponse).statusCode)")
                                logbookData = data
                                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                                   let data = json["data"] as? [[String: Any]] {
                                    for entry in data {
                                        let type = entry["type"] as! Int

                                        // TODO: type 3 has also an alarmType: 0 = fixedLow, 1 = low, 2 = high

                                        if type == 1 || type == 3 {  // measurement
                                            if let measurementData = try? JSONSerialization.data(withJSONObject: entry),
                                               let measurement = try? JSONDecoder().decode(GlucoseMeasurement.self, from: measurementData) {
                                                i += 1
                                                let date = dateFormatter.date(from: measurement.timestamp)!
                                                logbookHistory.append(LibreLinkUpGlucose(glucose: Glucose(measurement.valueInMgPerDl, id: i, date: date, source: "LibreLinkUp"), color: measurement.measurementColor, trendArrow: measurement.trendArrow))
                                                debugLog("LibreLinkUp: logbook measurement # \(i - history.count) of \(data.count): \(measurement) (JSON: \(entry))")
                                            }

                                        } else if type == 2 {  // alarm
                                            if let alarmData = try? JSONSerialization.data(withJSONObject: entry),
                                               var alarm = try? JSONDecoder().decode(LibreLinkUpAlarm.self, from: alarmData) {
                                                alarm.date = dateFormatter.date(from: alarm.timestamp)!
                                                logbookAlarms.append(alarm)
                                                debugLog("LibreLinkUp: logbook alarm: \(alarm) (JSON: \(entry))")
                                            }
                                        }
                                    }
                                    // TODO: merge with history and display trend arrow
                                    log("LibreLinkUp: logbook values: \(logbookHistory.map { ($0.glucose.id, $0.glucose.value, $0.glucose.date.shortDateTime, $0.color, $0.trendArrow!.symbol) }), alarms: \(logbookAlarms.map(\.description))")
                                }
                            }
                        }
                    }
                }
                return (data, response, history, logbookData, logbookHistory, logbookAlarms)
            } catch {
                log("LibreLinkUp: error while decoding response: \(error.localizedDescription)")
                throw LibreLinkUpError.jsonDecoding
            }
        } catch {
            log("LibreLinkUp: server error: \(error.localizedDescription)")
            throw LibreLinkUpError.noConnection
        }
    }

}
