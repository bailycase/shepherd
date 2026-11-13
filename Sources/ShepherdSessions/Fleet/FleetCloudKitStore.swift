import CloudKit
import Foundation
import Security

/// `FleetRendezvousStore` over the user's CloudKit private database. Every field goes in `encryptedValues`, so Apple's
/// servers hold only the record's name (a hash) and type. Not exercised by the test suite: CloudKit needs the container and a
/// provisioning profile, which a test process doesn't have (docs/releases.md, "iCloud rendezvous").
struct FleetCloudKitStore: FleetRendezvousStore {
    static let containerID = "iCloud.com.bailycase.shepherd"

    private let database: CKDatabase

    /// The store for the running build, or nil when the build can't use the container. Asking CloudKit for a container without the
    /// entitlement raises an Objective-C exception, so the signature is read first: a Dev build, an ad-hoc build and a release
    /// made without the provisioning profile all end here, quietly.
    private init?() {
        guard Self.isEntitled() else { return nil }
        database = CKContainer(identifier: Self.containerID).privateCloudDatabase
    }

    /// The store of this process: CloudKit when the build is entitled to the container, else one that says unavailable.
    static var forThisBuild: FleetRendezvousStore {
        if let store = FleetCloudKitStore() { return store }
        return UnavailableFleetRendezvousStore()
    }

    /// Whether this process was signed with the iCloud entitlements for the container (and so, by how macOS enforces
    /// them, runs with a profile that grants them).
    static func isEntitled() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        func entitlement(_ name: String) -> [String] {
            SecTaskCopyValueForEntitlement(task, name as CFString, nil) as? [String] ?? []
        }
        return entitlement("com.apple.developer.icloud-container-identifiers").contains(containerID)
            && entitlement("com.apple.developer.icloud-services").contains("CloudKit")
    }

    func put(_ record: FleetRendezvousRecord) async throws {
        let saved = CKRecord(recordType: record.key.kind.rawValue, recordID: CKRecord.ID(recordName: record.key.name))
        let fields = saved.encryptedValues
        fields["hostID"] = record.hostID.uuidString
        fields["name"] = record.name
        fields["port"] = Int(record.port)
        fields["routes"] = try JSONEncoder().encode(record.routes)
        fields["build"] = record.build
        fields["expiresAt"] = record.expiresAt
        fields["updatedAt"] = record.updatedAt
        do {
            // Replaces what is there: a presence record is written over and over.
            let (results, _) = try await database.modifyRecords(saving: [saved], deleting: [], savePolicy: .allKeys)
            for result in results.values { _ = try result.get() }
        } catch {
            throw Self.mapped(error)
        }
    }

    func fetch(_ key: FleetRendezvousKey) async throws -> FleetRendezvousRecord? {
        let fetched: CKRecord
        do {
            fetched = try await database.record(for: CKRecord.ID(recordName: key.name))
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        } catch {
            throw Self.mapped(error)
        }
        let fields = fetched.encryptedValues
        guard let id = (fields["hostID"] as String?).flatMap(UUID.init(uuidString:)),
              let routes = (fields["routes"] as Data?).flatMap({ try? JSONDecoder().decode([FleetAddress].self, from: $0) }) else { return nil }
        return FleetRendezvousRecord(key: key, hostID: id, name: fields["name"] as String? ?? "",
                                     port: (fields["port"] as Int?).flatMap { UInt16(exactly: $0) } ?? 0, routes: routes,
                                     build: fields["build"] as String?, expiresAt: fields["expiresAt"] as Double?,
                                     updatedAt: fields["updatedAt"] as Double? ?? 0)
    }

    func delete(_ key: FleetRendezvousKey) async throws {
        do {
            _ = try await database.deleteRecord(withID: CKRecord.ID(recordName: key.name))
        } catch let error as CKError where error.code == .unknownItem {
            return
        } catch {
            throw Self.mapped(error)
        }
    }

    private static func mapped(_ error: Error) -> FleetRendezvousError {
        guard let error = error as? CKError else { return .unavailable }
        return error.code == .notAuthenticated ? .noAccount : .unavailable
    }
}
