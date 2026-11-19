import Testing
import Foundation
@testable import Ghast

@Suite struct ScaleSetModelsTests {
    private static let stats = #"{"totalAvailableJobs":1,"totalAcquiredJobs":2,"totalAssignedJobs":3,"totalRunningJobs":4,"totalRegisteredRunners":5,"totalBusyRunners":6,"totalIdleRunners":7}"#

    private func data(_ text: String) -> Data { Data(text.utf8) }

    @Test("a session decodes its queue, token, scale set and statistics")
    func session() throws {
        let json = #"""
        {"sessionId":"6b1f0d2e-0c1a-4a56-9f00-1234567890ab","ownerName":"Dionysus",
         "runnerScaleSet":{"id":9,"name":"mac-vm","runnerGroupId":1,"labels":[{"name":"mac-vm","type":"System"}],"RunnerSetting":{"disableUpdate":true}},
         "messageQueueUrl":"https://pipelines.example/queue?x=1","messageQueueAccessToken":"qtok",
         "statistics":\#(Self.stats)}
        """#
        let session = try JSONDecoder().decode(ScaleSetSession.self, from: data(json))
        #expect(session.sessionID == "6b1f0d2e-0c1a-4a56-9f00-1234567890ab")
        #expect(session.ownerName == "Dionysus")
        #expect(session.scaleSet?.id == 9)
        #expect(session.messageQueueURL == "https://pipelines.example/queue?x=1")
        #expect(session.messageQueueAccessToken == "qtok")
        #expect(session.statistics == ScaleSetStatistics(
            totalAvailableJobs: 1, totalAcquiredJobs: 2, totalAssignedJobs: 3, totalRunningJobs: 4,
            totalRegisteredRunners: 5, totalBusyRunners: 6, totalIdleRunners: 7
        ))
    }

    @Test("a message decodes its body twice and sorts the four job message types, ignoring unknown ones")
    func message() throws {
        let elements = #"""
        [{"messageType":"JobAvailable","runnerRequestId":11,"acquireJobUrl":"https://a","jobId":"j1","jobDisplayName":"build","repositoryName":"ghast","ownerName":"octo","requestLabels":["mac-vm"],"queueTime":"2026-11-18T10:00:00Z"},
         {"messageType":"JobAssigned","runnerRequestId":12},
         {"messageType":"JobStarted","runnerRequestId":13,"runnerId":70,"runnerName":"mac-vm-a1b2c3"},
         {"messageType":"JobCompleted","runnerRequestId":14,"result":"succeeded","runnerId":71,"runnerName":"mac-vm-d4e5f6"},
         {"messageType":"SomethingNew","runnerRequestId":15}]
        """#
        let body = try String(data: JSONEncoder().encode(elements), encoding: .utf8)!
        let json = #"{"messageId":42,"messageType":"RunnerScaleSetJobMessages","body":\#(body),"statistics":\#(Self.stats)}"#

        let message = try ScaleSetMessage.decode(data(json))

        #expect(message.messageID == 42)
        #expect(message.statistics?.totalAssignedJobs == 3)
        #expect(message.jobsAvailable.map(\.runnerRequestID) == [11])
        #expect(message.jobsAvailable.first?.acquireJobURL == "https://a")
        #expect(message.jobsAvailable.first?.requestLabels == ["mac-vm"])
        #expect(message.jobsAvailable.first?.jobDisplayName == "build")
        #expect(message.jobsAssigned.map(\.runnerRequestID) == [12])
        #expect(message.jobsStarted.map(\.runnerName) == ["mac-vm-a1b2c3"])
        #expect(message.jobsStarted.map(\.runnerID) == [70])
        #expect(message.jobsCompleted.map(\.result) == ["succeeded"])
    }

    @Test("a message with an empty body has no jobs")
    func emptyBody() throws {
        let message = try ScaleSetMessage.decode(data(#"{"messageId":1,"messageType":"RunnerScaleSetJobMessages","body":""}"#))
        #expect(message.jobsAvailable.isEmpty)
        #expect(message.statistics == nil)
    }

    @Test("a scale-set JIT config decodes the runner id and encoded config")
    func jit() throws {
        let json = #"{"runner":{"id":77,"name":"mac-vm-a1b2c3","runnerScaleSetId":9},"encodedJITConfig":"QUJD"}"#
        let config = try JSONDecoder().decode(ScaleSetJITConfig.self, from: data(json))
        #expect(config.runner.id == 77)
        #expect(config.runner.runnerScaleSetID == 9)
        #expect(config.jit == GitHubJITConfig(runnerID: 77, encodedConfig: "QUJD"))
    }

    @Test("a scale-set list yields nil for none, the set for one, and an error for more", arguments: [0, 1, 2])
    func list(count: Int) throws {
        let set = #"{"id":9,"name":"mac-vm","runnerGroupId":1,"RunnerSetting":{}}"#
        let json = #"{"count":\#(count),"value":[\#(Array(repeating: set, count: count).joined(separator: ","))]}"#
        let list = try JSONDecoder().decode(ScaleSetList.self, from: data(json))
        switch count {
        case 0: #expect(try list.single() == nil)
        case 1: #expect(try list.single()?.id == 9)
        default: #expect(throws: ScaleSetError.self) { try list.single() }
        }
    }

    @Test("the create body names the set, its group and System label, and disables updates")
    func createBody() throws {
        let encoded = try JSONEncoder().encode(ScaleSetCreateRequest(name: "mac-vm", runnerGroupID: 3))
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["name"] as? String == "mac-vm")
        #expect(object["runnerGroupId"] as? Int == 3)
        #expect(object["createdOn"] as? String == "0001-01-01T00:00:00Z")
        let labels = try #require(object["labels"] as? [[String: String]])
        #expect(labels == [["name": "mac-vm", "type": "System"]])
        let setting = try #require(object["RunnerSetting"] as? [String: Bool])
        #expect(setting == ["disableUpdate": true])
        #expect(object["id"] == nil)
    }

    @Test("an exception body with a byte order mark maps to its kind", arguments: [
        ("GitHub.DistributedTask.WebApi.AgentExistsException", ActionsException.Kind.runnerExists),
        ("GitHub.DistributedTask.WebApi.AgentNotFoundException", .runnerNotFound),
        ("GitHub.DistributedTask.WebApi.JobStillRunningException", .jobStillRunning),
        ("SomethingElse", .other),
    ])
    func exceptionBody(typeName: String, kind: ActionsException.Kind) throws {
        let body = Data([0xEF, 0xBB, 0xBF]) + data(#"{"typeName":"\#(typeName)","message":"nope"}"#)
        let exception = try #require(ActionsException.parse(body))
        #expect(exception.kind == kind)
        #expect(exception.message == "nope")
    }

    @Test("a body that is not an exception parses to nil")
    func notAnException() {
        #expect(ActionsException.parse(data("oops")) == nil)
        #expect(ActionsException.parse(Data()) == nil)
    }

    @Test("a message of a type Ghast does not know keeps its id so it can be acknowledged, and nothing else", arguments: [
        (#"{"messageId":5,"messageType":"SomethingNew","body":"{not json"}"#, "SomethingNew"),
        (#"{"messageId":6,"messageType":7}"#, "(unreadable)"),
        (#"{"messageId":8}"#, "(unreadable)"),
    ])
    func unsupportedType(json: String, type: String) throws {
        let message = try ScaleSetMessage.decode(Data(json.utf8))
        #expect(message.unsupportedType == type)
        #expect(message.statistics == nil && message.jobsAvailable.isEmpty)
    }
}
