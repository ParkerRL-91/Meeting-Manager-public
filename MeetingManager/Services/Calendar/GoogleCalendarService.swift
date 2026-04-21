import Foundation
import os

// MARK: - GoogleCalendarError

enum GoogleCalendarError: LocalizedError {
    case invalidURL
    case httpError(statusCode: Int, message: String)
    case decodingError(Error)
    case networkError(Error)
    case noEvents

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid Google Calendar API URL."
        case .httpError(let statusCode, let message):
            return "Calendar API error (\(statusCode)): \(message)"
        case .decodingError(let error):
            return "Failed to parse calendar response: \(error.localizedDescription)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .noEvents:
            return "No events found for the specified time range."
        }
    }
}

// MARK: - API Response Types

/// Mirrors the Google Calendar API event list response.
private struct EventListResponse: Decodable, Sendable {
    let items: [EventResource]?
    let nextPageToken: String?
}

/// Mirrors a single Google Calendar API event resource.
private struct EventResource: Decodable, Sendable {
    let id: String
    let summary: String?
    let description: String?
    let start: EventDateTime?
    let end: EventDateTime?
    let attendees: [Attendee]?
    let hangoutLink: String?
    let conferenceData: ConferenceData?

    struct EventDateTime: Decodable, Sendable {
        let dateTime: String?
        let date: String?
    }

    struct Attendee: Decodable, Sendable {
        let email: String?
        let displayName: String?
    }

    struct ConferenceData: Decodable, Sendable {
        let entryPoints: [EntryPoint]?

        struct EntryPoint: Decodable, Sendable {
            let entryPointType: String?
            let uri: String?
        }
    }
}

/// Mirrors the Google Calendar API calendar list response.
private struct CalendarListResponse: Decodable, Sendable {
    let items: [CalendarResource]?
}

private struct CalendarResource: Decodable, Sendable {
    let id: String
    let summary: String?
    let primary: Bool?
}

// MARK: - GoogleCalendarService

/// Fetches calendar data from the Google Calendar REST API using plain
/// `URLSession`. When the GoogleAPIClientForREST SDK is integrated later,
/// the networking layer in this class can be replaced while keeping the
/// public interface stable.
final class GoogleCalendarService {

    private static let baseURL = "https://www.googleapis.com/calendar/v3"
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Public API

    /// Fetches calendar events in the given date range from the user's primary calendar.
    ///
    /// - Parameters:
    ///   - accessToken: A valid Google OAuth 2.0 access token.
    ///   - from: The start of the query window.
    ///   - to: The end of the query window.
    ///   - calendarId: The calendar to query (defaults to `"primary"`).
    /// - Returns: An array of `CalendarEvent` models.
    func fetchEvents(
        accessToken: String,
        from: Date,
        to: Date,
        calendarId: String = "primary"
    ) async throws -> [CalendarEvent] {
        let encodedCalendarId = calendarId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarId
        var components = URLComponents(string: "\(Self.baseURL)/calendars/\(encodedCalendarId)/events")!
        components.queryItems = [
            URLQueryItem(name: "timeMin", value: DateFormatting.iso8601FormatterNoFraction.string(from: from)),
            URLQueryItem(name: "timeMax", value: DateFormatting.iso8601FormatterNoFraction.string(from: to)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: "250"),
            URLQueryItem(name: "conferenceDataVersion", value: "1"),
        ]

        guard let url = components.url else {
            throw GoogleCalendarError.invalidURL
        }

        Logger.calendar.info("Fetching events from \(from) to \(to)")

        let allEvents: [CalendarEvent] = try await withRetry {
            var events: [CalendarEvent] = []
            var nextPageToken: String?
            var currentURL = url

            // Page through all results
            repeat {
                if let token = nextPageToken {
                    var paged = URLComponents(url: currentURL, resolvingAgainstBaseURL: false)!
                    var items = paged.queryItems ?? []
                    items.removeAll { $0.name == "pageToken" }
                    items.append(URLQueryItem(name: "pageToken", value: token))
                    paged.queryItems = items
                    currentURL = paged.url!
                }

                let request = self.authorizedRequest(url: currentURL, accessToken: accessToken)
                let (data, response) = try await self.performRequest(request)
                try self.validateHTTPResponse(response, data: data)

                let decoded: EventListResponse
                do {
                    decoded = try JSONDecoder().decode(EventListResponse.self, from: data)
                } catch {
                    throw GoogleCalendarError.decodingError(error)
                }

                let pageEvents = (decoded.items ?? []).compactMap { resource in
                    self.mapToCalendarEvent(resource, calendarId: calendarId)
                }
                events.append(contentsOf: pageEvents)
                nextPageToken = decoded.nextPageToken
            } while nextPageToken != nil

            return events
        }

        Logger.calendar.info("Fetched \(allEvents.count) events")
        return allEvents
    }

    /// Lists all calendars visible to the authenticated user.
    ///
    /// - Parameter accessToken: A valid Google OAuth 2.0 access token.
    /// - Returns: An array of `(id, name)` tuples.
    func listCalendars(accessToken: String) async throws -> [(id: String, name: String)] {
        guard let url = URL(string: "\(Self.baseURL)/users/me/calendarList") else {
            throw GoogleCalendarError.invalidURL
        }

        let request = authorizedRequest(url: url, accessToken: accessToken)
        let (data, response) = try await performRequest(request)
        try validateHTTPResponse(response, data: data)

        let decoded: CalendarListResponse
        do {
            decoded = try JSONDecoder().decode(CalendarListResponse.self, from: data)
        } catch {
            throw GoogleCalendarError.decodingError(error)
        }

        let calendars = (decoded.items ?? []).map { resource in
            (id: resource.id, name: resource.summary ?? resource.id)
        }

        Logger.calendar.info("Listed \(calendars.count) calendars")
        return calendars
    }

    // MARK: - Private Helpers

    private func authorizedRequest(url: URL, accessToken: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 120
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw GoogleCalendarError.networkError(error)
        }
    }

    private func validateHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleCalendarError.httpError(statusCode: 0, message: "Invalid response type")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            Logger.calendar.error("Calendar API HTTP \(httpResponse.statusCode): \(message)")
            throw GoogleCalendarError.httpError(statusCode: httpResponse.statusCode, message: message)
        }
    }

    /// Maps a Google Calendar API event resource to the app's `CalendarEvent` model.
    private func mapToCalendarEvent(_ resource: EventResource, calendarId: String) -> CalendarEvent? {
        let startDate = parseEventDate(resource.start)
        let endDate = parseEventDate(resource.end)

        guard let startDate, let endDate else {
            Logger.calendar.warning("Skipping event '\(resource.summary ?? "untitled")' — missing dates")
            return nil
        }

        // All-day events use a `date` field instead of `dateTime` in the API response.
        let isAllDay = resource.start?.date != nil

        let attendees = (resource.attendees ?? []).compactMap { attendee in
            attendee.displayName ?? attendee.email
        }
        if !attendees.isEmpty {
            Logger.calendar.debug("Event '\(resource.summary ?? "untitled")' has \(attendees.count) attendees")
        }

        // Prefer conference data entry point, fall back to hangoutLink.
        let meetLink = resource.conferenceData?.entryPoints?
            .first(where: { $0.entryPointType == "video" })?.uri
            ?? resource.hangoutLink

        return CalendarEvent(
            id: resource.id,
            title: resource.summary ?? "Untitled Event",
            startDate: startDate,
            endDate: endDate,
            isAllDay: isAllDay,
            attendees: attendees,
            meetLink: meetLink,
            description: resource.description,
            calendarId: calendarId
        )
    }

    // MARK: - Retry Helper

    /// Retries an operation with exponential backoff. Does NOT retry on 400/401/403 client errors.
    private func withRetry<T>(maxAttempts: Int = 3, operation: () async throws -> T) async throws -> T {
        var lastError: Error?
        for attempt in 0..<maxAttempts {
            do {
                return try await operation()
            } catch {
                lastError = error
                // Don't retry on client errors (400, 401, 403)
                if case GoogleCalendarError.httpError(let statusCode, _) = error,
                   [400, 401, 403].contains(statusCode) {
                    throw error
                }
                if attempt < maxAttempts - 1 {
                    let delay = pow(2.0, Double(attempt)) + Double.random(in: 0...1)
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
        }
        // maxAttempts >= 1 at call sites, so lastError is always set here. Guard
        // defensively anyway — a retry path must never be a crash vector.
        throw lastError ?? GoogleCalendarError.networkError(URLError(.unknown))
    }

    /// Parses a Google Calendar `EventDateTime` into a `Date`.
    /// Handles both `dateTime` (for timed events) and `date` (for all-day events).
    private func parseEventDate(_ eventDate: EventResource.EventDateTime?) -> Date? {
        guard let eventDate else { return nil }

        if let dateTimeString = eventDate.dateTime {
            // Try with fractional seconds first, then without
            if let date = DateFormatting.iso8601Formatter.date(from: dateTimeString) {
                return date
            }
            return DateFormatting.iso8601FormatterNoFraction.date(from: dateTimeString)
        }

        if let dateString = eventDate.date {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = .current
            return formatter.date(from: dateString)
        }

        return nil
    }
}
