// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import SwiftUI

struct ShellWorldClockSettingsSection: View {
    let configuration: ShellConfigurationCoordinator
    @State private var clocks: [ShellWorldClockEntry] = []
    @State private var saveError: String?

    var body: some View {
        Section("World Clock Locations") {
            ForEach($clocks) { clock in
                ShellWorldClockRow(clock: clock, canRemove: clocks.count > 1) {
                    clocks.removeAll { $0.id == clock.wrappedValue.id }
                }
            }
            HStack {
                Button("Add Clock", systemImage: "plus") {
                    clocks.append(ShellWorldClockEntry(label: "New York", zone: "America/New_York"))
                }
                .disabled(clocks.count >= 64)
                Spacer()
                Button("Apply Locations", action: applyLocations)
                    .disabled(!ShellWidgetSettingsModel.validClocks(clocks))
            }
            SettingsCaption(
                localized: "The order here is the order in the bar and popup. Locations are saved for the selected style."
            )
        }
        .onAppear { clocks = ShellWidgetSettingsModel.clocks(config: configuration.config) }
        .onChange(of: ShellWidgetSettingsModel
            .fields(widget: "world-clock", config: configuration.config)["zones"])
        { _, _ in
            clocks = ShellWidgetSettingsModel.clocks(config: configuration.config)
        }
        .shellSettingsError($saveError)
    }

    private func applyLocations() {
        Task {
            do { try await configuration.setWidgetOptions(clocks, widget: "world-clock", key: "zones") }
            catch { saveError = error.localizedDescription }
        }
    }
}

private struct ShellWorldClockRow: View {
    @Binding var clock: ShellWorldClockEntry
    let canRemove: Bool
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Label", text: $clock.label).textFieldStyle(.roundedBorder)
            Picker("Time Zone", selection: $clock.zone) {
                ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { zone in
                    Text(zone.replacingOccurrences(of: "_", with: " ")).tag(zone)
                }
            }
            Button("Remove Clock", role: .destructive, action: remove)
                .disabled(!canRemove)
                .controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}

struct ShellWeatherSettingsSection: View {
    struct Location: Encodable {
        var city: String?
        var latitude: Double?
        var longitude: Double?
        let units: String
        let refresh: Double
    }

    let configuration: ShellConfigurationCoordinator
    @State private var coordinates = false
    @State private var city = ""
    @State private var latitude = 0.0
    @State private var longitude = 0.0
    @State private var fahrenheit = false
    @State private var refresh = 15.0
    @State private var saveError: String?

    private var valid: Bool {
        coordinates ? latitude.isFinite && longitude.isFinite && (-90 ... 90).contains(latitude)
            && (-180 ... 180).contains(longitude) : !city.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Section("Weather Location") {
            SettingsCaption(localized: "Shared weather data for bar widgets, the calendar, and the island.")
            Picker("Location", selection: $coordinates) {
                Text("City").tag(false)
                Text("Coordinates").tag(true)
            }
            if coordinates {
                TextField("Latitude", value: $latitude, format: .number)
                TextField("Longitude", value: $longitude, format: .number)
                SettingsCaption(localized: "Latitude −90 to 90; longitude −180 to 180.")
            } else {
                TextField("City", text: $city).textFieldStyle(.roundedBorder)
            }
            Picker("Temperature", selection: $fahrenheit) {
                Text("Celsius").tag(false)
                Text("Fahrenheit").tag(true)
            }
            SettingsSliderRow(
                label: String(localized: "Refresh Interval"),
                value: $refresh,
                range: 5 ... 1440,
                step: 5,
                valueText: String(localized: "\(Int(refresh)) min")
            )
            Button("Apply Weather Location") {
                let location = Location(
                    city: coordinates ? nil : city.trimmingCharacters(in: .whitespacesAndNewlines),
                    latitude: coordinates ? latitude : nil,
                    longitude: coordinates ? longitude : nil,
                    units: fahrenheit ? "fahrenheit" : "celsius",
                    refresh: refresh
                )
                Task {
                    do { try await configuration.setWeather(location) }
                    catch { saveError = error.localizedDescription }
                }
            }
            .disabled(!valid)
        }
        .onAppear(perform: reload)
        .onChange(of: configuration.config.weather) { _, _ in reload() }
        .shellSettingsError($saveError)
    }

    private func reload() {
        guard let weather = configuration.config.weather else { return }
        switch weather.place {
        case let .city(value): coordinates = false
            city = value
        case let .coordinates(lat, lon): coordinates = true
            latitude = lat
            longitude = lon
        }
        fahrenheit = weather.fahrenheit
        refresh = Double(weather.refresh.components.seconds) / 60
    }
}
