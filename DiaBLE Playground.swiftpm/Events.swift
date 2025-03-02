import Foundation
import EventKit


class EventKit: Logging {

    var main: MainDelegate!
    var store: EKEventStore = EKEventStore()
    var calendarTitles = [String]()

    init(main: MainDelegate) {
        self.main = main
    }


    // https://github.com/JohanDegraeve/xdripswift/blob/master/xdrip/Managers/Watch/WatchManager.swift

    func sync(handler: ((EKCalendar?) -> Void)? = nil) {

        store.requestAccess(to: .event) { [self] granted, error  in
            guard granted else {
                debugLog("EventKit: access not granted")
                return
            }

            guard EKEventStore.authorizationStatus(for: .event) == .authorized else {
                log("EventKit: access to calendar events not authorized")
                return
            }

            self.calendarTitles = self.store.calendars(for: .event)
                .filter(\.allowsContentModifications)
                .map(\.title)

            guard self.main.settings.calendarTitle != "" else { return }

            var calendar: EKCalendar?
            for storeCalendar in self.store.calendars(for: .event) {
                if storeCalendar.title == self.main.settings.calendarTitle {
                    calendar = storeCalendar
                    break
                }
            }

            if calendar == nil {
                calendar = self.store.defaultCalendarForNewEvents
            }
            let predicate = self.store.predicateForEvents(withStart: Calendar.current.date(byAdding: .year, value: -1, to: Date())!, end: Date(), calendars: [calendar!])  // Date.distantPast doesn't work
            for event in self.store.events(matching: predicate) {
                if let notes = event.notes {
                    if notes.contains("Created by DiaBLE") {
                        do {
                            try self.store.remove(event, span: .thisEvent)
                        } catch {
                            debugLog("EventKit: error while deleting calendar events created by DiaBLE: \(error.localizedDescription)")
                        }
                    }
                }
            }

            let currentGlucose = self.main.app.currentGlucose
            var title = currentGlucose > 0 ? "\(currentGlucose.units)" : "---"

            if currentGlucose != 0 {
                title += "  \(self.main.settings.displayingMillimoles ? GlucoseUnit.mmoll : GlucoseUnit.mgdl)"

                let oopAlarm = self.main.app.oopAlarm
                if oopAlarm != .unknown {
                    title += "  \(oopAlarm.shortDescription)"
                } else {
                    if currentGlucose > Int(self.main.settings.alarmHigh) {
                        title += "  HIGH"
                    }
                    if currentGlucose < Int(self.main.settings.alarmLow) {
                        title += "  LOW"
                    }
                }

                let oopTrend = self.main.app.oopTrend
                if oopTrend != .unknown {
                    title += "  \(oopTrend.symbol)"
                }

                // TODO: delta

                let snoozed = self.main.settings.lastAlarmDate.timeIntervalSinceNow >= -Double(self.main.settings.alarmSnoozeInterval * 60) && self.main.settings.disabledNotifications

                let event = EKEvent(eventStore: self.store)
                event.title = title
                event.notes = "Created by DiaBLE"
                event.startDate = Date()
                event.endDate = Date(timeIntervalSinceNow: TimeInterval(60 * max(self.main.settings.readingInterval, self.main.settings.onlineInterval, snoozed ? self.main.settings.alarmSnoozeInterval : 0) + 5))
                event.calendar = calendar

                if !snoozed && self.main.settings.calendarAlarmIsOn {
                    if currentGlucose > 0 && (currentGlucose > Int(self.main.settings.alarmHigh) || currentGlucose < Int(self.main.settings.alarmLow)) {
                        let alarm = EKAlarm(relativeOffset: 1)
                        event.addAlarm(alarm)
                    }
                }

                do {
                    try self.store.save(event, span: .thisEvent)
                } catch {
                    log("EventKit: error while saving event: \(error.localizedDescription)")
                }
                handler?(calendar)
            }
        }
    }
}
