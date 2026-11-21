import Foundation
import CryptoKit
import Testing
@testable import SaytileKit

struct LocalFileProcessTests {
    @MainActor @Test(.enabled(if:ProcessInfo.processInfo.environment["NEARPANE_P4_FILE_CASE"] != nil))
    func coldFileJournalAndIndependentReopen() async throws {
        let env=ProcessInfo.processInfo.environment
        let caseDir=URL(fileURLWithPath:try #require(env["NEARPANE_P4_FILE_CASE"]))
        let root=caseDir.deletingLastPathComponent()
        guard root.deletingLastPathComponent().path=="/private/tmp",root.lastPathComponent.hasPrefix("nearpane-p4-corpus."),
              caseDir.lastPathComponent.range(of:"^case-[0-5]$",options:.regularExpression) != nil,
              ["record","reopen"].contains(env["NEARPANE_P4_FILE_PHASE"]) else { throw CocoaError(.fileReadNoPermission) }
        for dir in [root,caseDir] {
            var info=stat()
            guard lstat(dir.path,&info)==0,info.st_uid==getuid(),info.st_mode & 0o177777 == 0o40700 else {throw CocoaError(.fileReadNoPermission)}
        }
        let phase=env["NEARPANE_P4_FILE_PHASE"]!, directory=caseDir.appendingPathComponent("voice")
        let output=caseDir.appendingPathComponent(phase+".json"),input=caseDir.appendingPathComponent("stimulus.wav")
        guard !FileManager.default.fileExists(atPath:output.path), (phase=="record") != FileManager.default.fileExists(atPath:directory.path) else {throw CocoaError(.fileWriteFileExists)}
        var sourceStat=stat()
        guard lstat(input.path,&sourceStat)==0,sourceStat.st_uid==getuid(),sourceStat.st_mode & S_IFMT==S_IFREG,sourceStat.st_nlink==1,sourceStat.st_size<1_000_000,
              sourceStat.st_size>44 else {throw CocoaError(.fileReadNoPermission)}
        let store=try SaytileStore(directory:directory)
        var result:[String:Any]=["phase":phase,"actualProcessID":getpid(),"sourceSHA256":SHA256.hash(data:try Data(contentsOf:input)).map{String(format:"%02x",$0)}.joined()]
        if phase=="record" {
            let capability=await AppleSpeechService.availability()
            let audio=AudioController(store:store,startupRecoveryReady:false)
            result["appleDefaultInstalled"]=capability.installed
            result["route"]=capability.installed ? "Saytile default local SpeechTranscriber":"Saytile recordOnly file ingress"
            _=try await audio.replayLocalFixture(input,recordOnly:!capability.installed)
            await audio.shutdown()
        }
        let rows=try await store.listRecordings()
        var recordings=[[String:Any]]()
        for row in rows {
            let proof=await NearpaneVoiceReadback.read(row.id,store:store)
            let final=try await store.latestFinalRevision(recordingID:row.id)
            var entry:[String:Any]=["id":row.id.uuidString,"state":proof.state.rawValue,"frames":proof.frames]
            entry["audioSHA256"]=proof.audioSHA256
            entry["finalSHA256"]=proof.finalSHA256
            entry["preferredFinalID"]=proof.state == .final ? final?.id.uuidString : nil
            if proof.state == .final, let final {
                // The selected input is always one of the three prescribed isolated utterances.
                entry["textForFixtureScoring"]=final.text
            }
            entry["chunks"]=try await store.audioChunks(recordingID:row.id).map { ["relative":$0.relativePath,"frames":$0.frames] as [String:Any] }
            recordings.append(entry)
        }
        result["recordings"]=recordings
        try await store.close()
        try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]).write(to:output,options:.withoutOverwriting)
    }
}
