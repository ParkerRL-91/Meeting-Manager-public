import Foundation
import Contacts
import os

/// Opt-in import of macOS Contacts to bootstrap the Person identity directory.
/// Only names and email addresses are read — no phone numbers, photos, or
/// address data. Imported persons are indistinguishable from calendar-sourced
/// ones and benefit from the same voice-matching pipeline.
///
/// Usage: call `importContacts(into:)` after the user enables the toggle in
/// Settings → People. Re-calling is safe; existing persons are updated (aliases
/// merged) rather than duplicated.
@MainActor
final class ContactsImportService {
    static let shared = ContactsImportService()
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.meetingmanager.app",
        category: "ContactsImport"
    )

    private init() {}

    // MARK: - Authorization

    var authorizationStatus: CNAuthorizationStatus {
        CNContactStore.authorizationStatus(for: .contacts)
    }

    /// Request Contacts access. Returns true when access is granted.
    func requestAccess() async -> Bool {
        let store = CNContactStore()
        do {
            return try await store.requestAccess(for: .contacts)
        } catch {
            logger.error("Contacts access request failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Import

    /// Import contacts into the Person directory.
    /// - Returns: (created, updated) count of Person records.
    func importContacts(into personRepo: PersonRepository) async -> (created: Int, updated: Int) {
        guard authorizationStatus == .authorized else {
            logger.warning("Contacts import skipped — not authorized")
            return (0, 0)
        }

        let store = CNContactStore()
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]

        var contacts: [CNContact] = []
        let request = CNContactFetchRequest(keysToFetch: keysToFetch)
        request.sortOrder = .userDefault
        do {
            try store.enumerateContacts(with: request) { contact, _ in
                // Only import contacts that have at least a name or an email
                let hasName = !contact.givenName.isEmpty || !contact.familyName.isEmpty
                let hasEmail = !contact.emailAddresses.isEmpty
                if hasName || hasEmail {
                    contacts.append(contact)
                }
            }
        } catch {
            logger.error("Contacts enumeration failed: \(error.localizedDescription, privacy: .public)")
            return (0, 0)
        }

        logger.info("ContactsImport: found \(contacts.count) contacts to process")

        var created = 0
        var updated = 0

        for contact in contacts {
            let displayName = fullName(contact)
            let emails = contact.emailAddresses.map { $0.value as String }

            // Build all raw aliases for this contact
            var rawAliases = emails
            if !displayName.isEmpty { rawAliases.insert(displayName, at: 0) }
            guard !rawAliases.isEmpty else { continue }

            // Use the display name as the primary key if available, else first email
            let primary = displayName.isEmpty ? rawAliases[0] : displayName
            let existing = try? await personRepo.find(for: primary)

            if existing == nil {
                _ = try? await personRepo.findOrCreate(for: primary)
                // Merge remaining aliases
                if let person = try? await personRepo.find(for: primary) {
                    for alias in rawAliases.dropFirst() {
                        try? await personRepo.addAlias(alias, toPersonId: person.id)
                    }
                }
                created += 1
            } else if let person = existing {
                // Merge any new aliases we didn't have before
                var addedAny = false
                for alias in rawAliases {
                    if !person.aliases.contains(alias) {
                        try? await personRepo.addAlias(alias, toPersonId: person.id)
                        addedAny = true
                    }
                }
                if addedAny { updated += 1 }
            }
        }

        logger.info("ContactsImport: created=\(created) updated=\(updated)")
        return (created, updated)
    }

    // MARK: - Helpers

    private func fullName(_ contact: CNContact) -> String {
        let parts = [contact.givenName, contact.familyName]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.joined(separator: " ")
    }
}
