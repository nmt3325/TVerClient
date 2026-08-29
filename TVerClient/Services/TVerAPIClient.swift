import Foundation

final class TVerAPIClient: TVerCatalogServicing, @unchecked Sendable {
    func fetchSchedule() async throws -> [ProgramDay] { [] }
}
