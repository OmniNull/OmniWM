// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

struct ShellWeatherLocation: Equatable, Sendable {
    enum Place: Equatable, Sendable {
        case city(String)
        case coordinates(latitude: Double, longitude: Double)
    }

    var place: Place
    var fahrenheit = false
    var refresh = Duration.seconds(15 * 60)
    var name: String?
}

struct ShellWeatherReading: Sendable {
    let weather: ShellWeather
    let latitude: Double
    let longitude: Double
}

struct ShellWeatherHour: Equatable, Sendable {
    let time: Double
    let label: String
    let temp: Double
    let code: Int
    let day: Bool
    let rain: Double?
}

struct ShellWeatherDay: Equatable, Sendable {
    let time: Double
    let label: String
    let high: Double
    let low: Double
    let code: Int
    let rain: Double?
}

struct ShellWeather: Equatable, Sendable {
    var temp: Double
    var feels: Double?
    var high: Double?
    var low: Double?
    var rain: Double?
    var wind: Double?
    var humidity: Double?
    var sunrise: Double?
    var sunset: Double?
    var code: Int
    var day: Bool
    var unit: String
    var place: String?
    var stale = false
    var hours: [ShellWeatherHour] = []
    var days: [ShellWeatherDay] = []

    var condition: (name: String, symbol: String) {
        Self.condition(code: code, day: day)
    }

    static func condition(code: Int, day: Bool) -> (name: String, symbol: String) {
        switch code {
        case 0: ("Clear", day ? "sun.max" : "moon.stars")
        case 1,
             2: ("Partly cloudy", day ? "cloud.sun" : "cloud.moon")
        case 3: ("Overcast", "cloud")
        case 45,
             48: ("Fog", "cloud.fog")
        case 51,
             53,
             55: ("Drizzle", "cloud.drizzle")
        case 56,
             57,
             66,
             67: ("Freezing rain", "cloud.sleet")
        case 61,
             63,
             65,
             80,
             81,
             82: ("Rain", "cloud.rain")
        case 71,
             73,
             75,
             77,
             85,
             86: ("Snow", "cloud.snow")
        case 95,
             96,
             99: ("Thunderstorms", "cloud.bolt.rain")
        default: ("Unknown", "cloud")
        }
    }
}

extension ShellWeather {
    func write(into writer: inout ShellValueWriter) {
        let optional = [
            ("feels", feels), ("high", high), ("low", low), ("rain", rain), ("wind", wind),
            ("humidity", humidity), ("sunrise", sunrise), ("sunset", sunset)
        ]
        .compactMap { key, value in value.map { (key, $0) } }
        writer.map(9 + optional.count + (place == nil ? 0 : 1))
        writer.key("temp")
        writer.number(temp)
        for (key, value) in optional {
            writer.key(key)
            writer.number(value)
        }
        writer.key("code")
        writer.number(Double(code))
        writer.key("day")
        writer.bool(day)
        writer.key("unit")
        writer.string(unit)
        writer.key("condition")
        writer.string(condition.name)
        writer.key("symbol")
        writer.string(condition.symbol)
        if let place {
            writer.key("place")
            writer.string(place)
        }
        writer.key("status")
        writer.string(stale ? "stale" : "ok")
        writeHours(into: &writer)
        writeDays(into: &writer)
    }

    private func writeHours(into writer: inout ShellValueWriter) {
        writer.key("hours")
        writer.array(hours.count)
        for hour in hours {
            let condition = Self.condition(code: hour.code, day: hour.day)
            writer.map(hour.rain == nil ? 7 : 8)
            writer.key("time")
            writer.number(hour.time)
            writer.key("code")
            writer.number(Double(hour.code))
            writer.key("label")
            writer.string(hour.label)
            writer.key("temp")
            writer.number(hour.temp)
            writer.key("condition")
            writer.string(condition.name)
            writer.key("symbol")
            writer.string(condition.symbol)
            writer.key("day")
            writer.bool(hour.day)
            if let rain = hour.rain {
                writer.key("rain")
                writer.number(rain)
            }
        }
    }

    private func writeDays(into writer: inout ShellValueWriter) {
        writer.key("days")
        writer.array(days.count)
        for day in days {
            let condition = Self.condition(code: day.code, day: true)
            writer.map(day.rain == nil ? 7 : 8)
            writer.key("time")
            writer.number(day.time)
            writer.key("code")
            writer.number(Double(day.code))
            writer.key("label")
            writer.string(day.label)
            writer.key("high")
            writer.number(day.high)
            writer.key("low")
            writer.number(day.low)
            writer.key("condition")
            writer.string(condition.name)
            writer.key("symbol")
            writer.string(condition.symbol)
            if let rain = day.rain {
                writer.key("rain")
                writer.number(rain)
            }
        }
    }
}

enum ShellWeatherClient {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()

    static func forecast(_ location: ShellWeatherLocation) async throws -> ShellWeatherReading {
        let coordinates = try await coordinates(of: location.place)
        let url = try url(host: "api.open-meteo.com", path: "/v1/forecast", query: [
            "latitude": String(coordinates.latitude),
            "longitude": String(coordinates.longitude),
            "current": "temperature_2m,apparent_temperature,is_day,weather_code,wind_speed_10m,relative_humidity_2m",
            "hourly": "temperature_2m,weather_code,is_day,precipitation_probability",
            "daily": "temperature_2m_max,temperature_2m_min,precipitation_probability_max,weather_code,sunrise,sunset",
            "temperature_unit": location.fahrenheit ? "fahrenheit" : "celsius",
            "wind_speed_unit": location.fahrenheit ? "mph" : "kmh",
            "timezone": "auto",
            "timeformat": "unixtime",
            "forecast_hours": "24",
            "forecast_days": "7"
        ])
        var weather = try await weather(from: load(url), fahrenheit: location.fahrenheit)
        weather.place = location.name ?? coordinates.name
        return ShellWeatherReading(weather: weather, latitude: coordinates.latitude, longitude: coordinates.longitude)
    }

    static func weather(
        from data: Data,
        fahrenheit: Bool,
        locale: Locale = .autoupdatingCurrent
    ) throws -> ShellWeather {
        let report = try JSONDecoder().decode(WeatherReport.self, from: data)
        guard report.current.temperature.isFinite else { throw URLError(.cannotParseResponse) }
        let zone = report.offset.flatMap(TimeZone.init(secondsFromGMT:)) ?? .autoupdatingCurrent
        return ShellWeather(
            temp: report.current.temperature,
            feels: report.current.feelsLike,
            high: report.daily?.high.first ?? nil,
            low: report.daily?.low.first ?? nil,
            rain: report.daily?.rain.first ?? nil,
            wind: report.current.windSpeed,
            humidity: report.current.humidity,
            sunrise: report.daily?.sunrise?.first ?? nil,
            sunset: report.daily?.sunset?.first ?? nil,
            code: report.current.code,
            day: report.current.isDay == 1,
            unit: fahrenheit ? "°F" : "°C",
            hours: report.hourly.map { hours($0, zone: zone, locale: locale) } ?? [],
            days: report.daily.map { days($0, zone: zone, locale: locale) } ?? []
        )
    }

    private static func hours(_ hourly: WeatherHourly, zone: TimeZone, locale: Locale) -> [ShellWeatherHour] {
        let label = formatter(zone: zone, locale: locale) { $0.setLocalizedDateFormatFromTemplate("j") }
        return hourly.time.indices.compactMap { index in
            guard index < hourly.temperature.count, index < hourly.code.count,
                  let temp = hourly.temperature[index], let code = hourly.code[index]
            else {
                return nil
            }
            let time = hourly.time[index]
            return ShellWeatherHour(
                time: time,
                label: label.string(from: Date(timeIntervalSince1970: time)),
                temp: temp,
                code: code,
                day: (index < hourly.isDay.count ? hourly.isDay[index] : 1) == 1,
                rain: hourly.rain.flatMap { index < $0.count ? $0[index] : nil }
            )
        }
    }

    private static func days(_ daily: WeatherDaily, zone: TimeZone, locale: Locale) -> [ShellWeatherDay] {
        let weekday = formatter(zone: zone, locale: locale) { $0.setLocalizedDateFormatFromTemplate("EEE") }
        let relative = formatter(zone: zone, locale: locale) {
            $0.dateStyle = .medium
            $0.doesRelativeDateFormatting = true
        }
        guard let times = daily.time, let codes = daily.code else { return [] }
        return times.indices.compactMap { index in
            guard index < daily.high.count, index < daily.low.count, index < codes.count,
                  let high = daily.high[index], let low = daily.low[index], let code = codes[index]
            else {
                return nil
            }
            let date = Date(timeIntervalSince1970: times[index])
            return ShellWeatherDay(
                time: times[index],
                label: index == 0 ? relative.string(from: date) : weekday.string(from: date),
                high: high,
                low: low,
                code: code,
                rain: index < daily.rain.count ? daily.rain[index] : nil
            )
        }
    }

    private static func formatter(
        zone: TimeZone,
        locale: Locale,
        _ configure: (DateFormatter) -> Void
    ) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = zone
        configure(formatter)
        return formatter
    }

    private static func coordinates(of place: ShellWeatherLocation.Place) async throws -> WeatherPlace {
        switch place {
        case let .coordinates(latitude, longitude):
            return WeatherPlace(latitude: latitude, longitude: longitude, name: nil)
        case let .city(name):
            let url = try url(host: "geocoding-api.open-meteo.com", path: "/v1/search", query: [
                "name": name,
                "count": "1",
                "format": "json"
            ])
            guard let first = try await JSONDecoder().decode(WeatherSearch.self, from: load(url)).results?.first else {
                throw URLError(.cannotFindHost)
            }
            return WeatherPlace(latitude: first.latitude, longitude: first.longitude, name: first.name ?? name)
        }
    }

    private static func url(host: String, path: String, query: KeyValuePairs<String, String>) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw URLError(.badURL) }
        return url
    }

    private static func load(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}

private struct WeatherReport: Decodable {
    let current: WeatherCurrent
    let daily: WeatherDaily?
    let hourly: WeatherHourly?
    let offset: Int?

    enum CodingKeys: String, CodingKey {
        case current, daily, hourly
        case offset = "utc_offset_seconds"
    }
}

private struct WeatherCurrent: Decodable {
    let temperature: Double
    let feelsLike: Double?
    let isDay: Int
    let code: Int
    let windSpeed: Double?
    let humidity: Double?

    enum CodingKeys: String, CodingKey {
        case temperature = "temperature_2m"
        case feelsLike = "apparent_temperature"
        case isDay = "is_day"
        case code = "weather_code"
        case windSpeed = "wind_speed_10m"
        case humidity = "relative_humidity_2m"
    }
}

private struct WeatherDaily: Decodable {
    let time: [Double]?
    let high: [Double?]
    let low: [Double?]
    let rain: [Double?]
    let code: [Int?]?
    let sunrise: [Double?]?
    let sunset: [Double?]?

    enum CodingKeys: String, CodingKey {
        case time, sunrise, sunset
        case high = "temperature_2m_max"
        case low = "temperature_2m_min"
        case rain = "precipitation_probability_max"
        case code = "weather_code"
    }
}

private struct WeatherHourly: Decodable {
    let time: [Double]
    let temperature: [Double?]
    let code: [Int?]
    let isDay: [Int?]
    let rain: [Double?]?

    enum CodingKeys: String, CodingKey {
        case time
        case temperature = "temperature_2m"
        case code = "weather_code"
        case isDay = "is_day"
        case rain = "precipitation_probability"
    }
}

private struct WeatherSearch: Decodable {
    let results: [WeatherPlace]?
}

private struct WeatherPlace: Decodable {
    let latitude: Double
    let longitude: Double
    let name: String?
}
