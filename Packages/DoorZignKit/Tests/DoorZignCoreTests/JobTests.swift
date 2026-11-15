import Foundation
import Testing
@testable import DoorZignCore

@Suite struct JobTests {
    @Test func pollingRegel() {
        let start = Date(timeIntervalSince1970: 0)
        #expect(JobPolling.interval(hasOpenJobs: false, fastSince: nil, now: start) == .seconds(30))
        #expect(JobPolling.interval(hasOpenJobs: true, fastSince: start, now: start.addingTimeInterval(10)) == .seconds(5))
        #expect(JobPolling.interval(hasOpenJobs: true, fastSince: start, now: start.addingTimeInterval(299)) == .seconds(5))
        #expect(JobPolling.interval(hasOpenJobs: true, fastSince: start, now: start.addingTimeInterval(300)) == .seconds(30))
    }

    @Test func statusTexte() {
        #expect(JobStatus.retry.label == "Neuer Versuch geplant")
        #expect(JobStatus.allCases.filter(\.isOpen) == [.pending, .progress, .retry])
    }

    @Test func geplanteAuftraegeSindNichtAktiv() {
        let future = Job(scheduledAt: Date().addingTimeInterval(3600), id: "j", displayId: "d",
                         _type: "upload_image", status: .pending, createdAt: Date())
        #expect(!future.isActive())
        let unknown = Job(id: "j", displayId: "d", _type: "neuer_typ", status: .done, createdAt: Date())
        #expect(unknown.typeLabel == "Auftrag")
    }
}

@Suite struct SlotTransferStatusTests {
    static func slot(transferred: Bool, transfer: Job? = nil) -> Slot {
        Slot(slot: 2, content: .deactivated(.init(_type: .deactivated)), transferred: transferred,
             editable: true, etag: "e", transfer: transfer)
    }

    @Test func inaktivNichtUebertragenIstKeinFehler() {
        #expect(Self.slot(transferred: false).transferStatus(isActive: false).tone == .neutral)
        #expect(Self.slot(transferred: false).transferStatus(isActive: true).tone == .warning)
        #expect(Self.slot(transferred: true).transferStatus(isActive: true).label == "Auf dem Display")
        let failed = Job(id: "j", displayId: "d", _type: "upload_image", status: .failed, createdAt: Date())
        #expect(Self.slot(transferred: false, transfer: failed).transferStatus(isActive: false).tone == .failure)
    }
}
