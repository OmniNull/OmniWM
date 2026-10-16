// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import CoreAudio
import IOKit.ps

extension ShellDataFeed {
    func setWeatherLocation(_ location: ShellWeatherLocation?) {
        guard location != weatherLocation else { return }
        weatherLocation = location
        weatherQuery = location
        weatherTask?.cancel()
        weatherTask = nil
        nextWeather = nil
        data.weather = nil
        updateWeather()
        publish()
    }

    func updateWeather() {
        guard !paused, demands(.weather), let query = weatherQuery else {
            weatherTask?.cancel()
            weatherTask = nil
            return
        }
        guard weatherTask == nil, nextWeather.map({ ContinuousClock.now >= $0 }) ?? true else { return }
        weatherTask = Task { [weak self, loadWeather] in
            let result: Result<ShellWeatherReading, any Error>
            do {
                result = try await .success(loadWeather(query))
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled, let self else { return }
            weatherTask = nil
            switch result {
            case let .failure(error):
                Log.shell.error("Weather update failed: \(error.localizedDescription)")
                nextWeather = .now + Self.weatherRetry
                if data.weather?.stale == false {
                    data.weather?.stale = true
                    publish()
                }
            case let .success(reading):
                nextWeather = .now + query.refresh
                weatherQuery = ShellWeatherLocation(
                    place: .coordinates(latitude: reading.latitude, longitude: reading.longitude),
                    fahrenheit: query.fahrenheit,
                    refresh: query.refresh,
                    name: reading.weather.place
                )
                guard data.weather != reading.weather else { return }
                data.weather = reading.weather
                publish()
            }
        }
    }

    func updateProviders() {
        if !paused {
            sampleSystem()
        }
        updateAudio()
        listAudioApps(!paused && demands(.audioApps))
        listenToMedia(!paused && (demands(.media) || demands(.lyrics)))
        showLyrics(!paused && demands(.lyrics))
        listenToCalendar(!paused && demands(.calendar))
        listenToReminders(!paused && demands(.reminders))
        listenToBadges()
        devices.map(listenToDevices)
        updateBattery()
        updateWeather()
        reschedule()
    }

    func listenToCalendar(_ listening: Bool) {
        guard let calendar else { return }
        calendar.setListening(listening)
        guard listening else {
            calendar.onChange = nil
            data.calendar = nil
            return
        }
        calendar.onChange = { [weak self] value in
            guard let self, data.calendar != value else { return }
            data.calendar = value
            publish()
        }
        data.calendar = calendar.calendar
    }

    func listenToReminders(_ listening: Bool) {
        guard let calendar else { return }
        calendar.setRemindersListening(listening)
        guard listening else {
            calendar.onRemindersChange = nil
            data.reminders = nil
            return
        }
        calendar.onRemindersChange = { [weak self] value in
            guard let self, data.reminders != value else { return }
            data.reminders = value
            publish()
        }
        data.reminders = calendar.reminders
    }

    func listenToMedia(_ listening: Bool) {
        guard let media else { return }
        media.setListening(listening)
        guard listening else {
            media.onChange = nil
            data.media = nil
            return
        }
        media.onChange = { [weak self] value in
            guard let self, data.media != value else { return }
            data.media = value
            showLyrics(!paused && demands(.lyrics))
            publish()
        }
        data.media = media.media
    }

    func showLyrics(_ shown: Bool) {
        lyrics.show(shown ? data.media.flatMap(ShellLyricsTrack.init) : nil)
        data.lyrics = shown ? lyrics.lyrics : nil
    }

    func listAudioApps(_ listed: Bool) {
        guard let appVolumes else { return }
        appVolumes.setListing(listed)
        guard listed else {
            appVolumes.onChange = nil
            data.audioApps = nil
            return
        }
        appVolumes.onChange = { [weak self] apps in
            guard let self, data.audioApps != apps else { return }
            data.audioApps = apps
            publish()
        }
        data.audioApps = appVolumes.apps
    }
}
