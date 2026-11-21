import CoreServices
import CryptoKit
import Foundation
import NearpaneCore
import SwiftUI
import Testing
@testable import NearpaneUI

struct DictionaryContentQualificationTests {
    @MainActor @Test(.enabled(if:ProcessInfo.processInfo.environment["NEARPANE_P4_DICTIONARY_RECEIPT"] != nil))
    func offscreenDictionaryTermUsesProductionContentAndReopensFixtureWord() throws {
        let destination=URL(fileURLWithPath:try #require(ProcessInfo.processInfo.environment["NEARPANE_P4_DICTIONARY_RECEIPT"]))
        let term="bicycle",known="自行车",range=DCSGetTermRangeInString(nil,"bicycle" as CFString,0)
        guard range.location==0,range.length==term.utf16.count,
              let definition=DCSCopyTextDefinition(nil,term as CFString,range)?.takeRetainedValue() as String?,
              definition.contains(known) else {
            try Data(#"{"status":"BLOCKED_LOCAL_DICTIONARY_TERM_UNAVAILABLE"}"#.utf8).write(to:destination,options:.withoutOverwriting);return
        }
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
            .appendingPathComponent(ProcessInfo.processInfo.environment["NEARPANE_TEST_DIRECTORY"] ?? ".build/test-data")
            .appendingPathComponent("dictionary-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let request=try TranslationRequest(term,generation:UUID())
        func render(_ value:String) throws -> (String,Int,Int) {
            let renderer=ImageRenderer(content:TranslationResultContent(text:value,request:request.id))
            renderer.scale=1
            let image=try #require(renderer.cgImage)
            let bitmap=NSBitmapImageRep(cgImage:image)
            let png=try #require(bitmap.representation(using:.png,properties:[:]))
            return (LocalToolStage.digest(png),image.width,image.height)
        }
        let answer=try render(known),empty=try render(""),loading=try render("正在查询…")
        #expect(answer.0 != empty.0 && answer.0 != loading.0 && answer.1>20 && answer.2>15)
        let word=try SidebarNotebook(directory:root).commit(request,answer:known,from:"en",to:"zh-Hans",provider:"Controlled Dictionary Services fixture")
        let found=try SidebarNotebook(directory:root).diskWord(for:request.id)
        let reopened=try #require(found)
        #expect(word==reopened && reopened.translation==known)
        let receipt:[String:Any]=["status":"PASS_OFFSCREEN_CONTENT","term":term,"controlledResult":known,
            "readOnlyDictionaryLookup":true,"fullDefinitionSaved":false,"productionDefaultProviderChanged":false,
            "dictionaryDefinitionSHA256":LocalToolStage.digest(Data(definition.utf8)),"request":request.id.uuidString,
            "actualContentSHA256":answer.0,"emptyControlSHA256":empty.0,"loadingControlSHA256":loading.0,
            "renderedSize":[answer.1,answer.2],"wordID":word.id.uuidString,"wordReadAfterOpeningNewNotebook":true,
            "nsServicesCallback":"NOT_RUN","windowOrdered":false,"userVisibleNonactivatingPanel":"NOT_RUN","appleTranslationSessionResult":"NOT_RUN"]
        try JSONSerialization.data(withJSONObject:receipt,options:[.sortedKeys,.prettyPrinted]).write(to:destination,options:.withoutOverwriting)
    }
}
