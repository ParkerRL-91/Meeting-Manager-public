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
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        let encodedCalendarId = calendarId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarId
        var components = URLComponents(string: "\(Self.baseURL)/calendars/\(encodedCalendarId)/events")!
        components.queryItems = [
            URLQueryItem(name: "timeMin", value: formatter.string(from: from)),
            URLQueryItem(name: "timeMax", value: formatter.string(from: to)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: "250"),
        ]

        guard let url = components.url else {
            throw GoogleCalendarError.invalidURL
        }

        Logger.calendar.info("Fetching events from \(from) to \(to)")

        var allEvents: [CalendarEvent] = []
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

            let request = authorizedRequest(url: currentURL, accessToken: accessToken)
            let (data, response) = try await performRequest(request)
            try validateHTTPResponse(response, data: data)

            let decoded: EventListResponse
            do {
                decoded = try JSONDecoder().decode(EventListResponse.self, from: data)
            } catch {
                throw GoogleCalendarError.decodingError(error)
            }

            let events = (decoded.items ?? []).compactMap { resource in
                mapToCalendarEvent(resource, calendarId: calendarId)
            }
            allEvents.append(contentsOf: events)
            nextPageToken = decoded.nextPageToken
        } while nextPageToken != nil

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

        let attendees = (resource.attendees ?? []).compactMap { attendee in
            attendee.displayName ?? attendee.email
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
            attendees: attendees,
            meetLink: meetLink,
            description: resource.description,
            calendarId: calendarId
        )
    }

    /// Parses a Google Calendar `EventDateTime` into a `Date`.
    /// Handles both `dateTime` (for timed events) and `date` (for all-day events).
    private func parseEventDate(_ eventDate: EventResource.EventDateTime?) -> Date? {
        guard let eventDate else { return nil }

        if let dateTimeString = eventDate.dateTime {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: dateTimeString) {
                return date
            }
            // Retry without fractional seconds
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: dateTimeString)
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
