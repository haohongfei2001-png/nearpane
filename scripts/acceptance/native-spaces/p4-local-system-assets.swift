// Read-only availability of installed Apple sources. This executable has no authorization or asset-install path.
import Foundation
import Speech
import Translation
import CoreServices
import CryptoKit

private func speech(_ status:AssetInventory.Status)->String {
    switch status { case .installed:"installed";case .supported:"supported";case .unsupported:"unsupported";case .downloading:"downloading";@unknown default:"unknown" }
}
private func language(_ status:LanguageAvailability.Status)->String {
    switch status { case .installed:"installed";case .supported:"supported";case .unsupported:"unsupported";@unknown default:"unknown" }
}
private func digest(_ s:String)->String { SHA256.hash(data:Data(s.utf8)).map { String(format:"%02x",$0) }.joined() }

@main struct Assets {
    static func main() async {
        var evidence:[String:Any]=[:]
        let locale=Locale(identifier:"zh-CN")
        if let concrete=await SpeechTranscriber.supportedLocale(equivalentTo:locale) {
            let m=SpeechTranscriber(locale:concrete,preset:.progressiveTranscription)
            evidence["saytileSpeechTranscriber"]=["locale":concrete.identifier,"inventory":speech(await AssetInventory.status(forModules:[m])),
                              "installedLocale":await SpeechTranscriber.installedLocales.contains(concrete)] as [String:Any]
            var choices=[String:String]()
            for (key,preset) in [("transcription",SpeechTranscriber.Preset.transcription),("progressive",.progressiveTranscription),("timeIndexedProgressive",.timeIndexedProgressiveTranscription)] {
                choices[key]=speech(await AssetInventory.status(forModules:[SpeechTranscriber(locale:concrete,preset:preset)]))
            }
            evidence["mandarinSpeechPresets"]=choices
        } else { evidence["saytileSpeechTranscriber"]=["inventory":"unsupportedLocale"] }
        if let concrete=await DictationTranscriber.supportedLocale(equivalentTo:locale) {
            let m=DictationTranscriber(locale:concrete,preset:.shortDictation)
            evidence["separateDictationTranscriber"]=["locale":concrete.identifier,"inventory":speech(await AssetInventory.status(forModules:[m])),
                                         "installedLocale":await DictationTranscriber.installedLocales.contains(concrete)] as [String:Any]
            var choices=[String:String]()
            for (key,preset) in [("phrase",DictationTranscriber.Preset.phrase),("short",.shortDictation),("long",.longDictation)] {
                choices[key]=speech(await AssetInventory.status(forModules:[DictationTranscriber(locale:concrete,preset:preset)]))
            }
            evidence["mandarinDictationPresets"]=choices
        } else { evidence["separateDictationTranscriber"]=["inventory":"unsupportedLocale"] }
        let old=SFSpeechRecognizer.authorizationStatus()
        evidence["legacySpeechPermission"]=old.rawValue
        if old == .authorized,let recognizer=SFSpeechRecognizer(locale:locale) {
            evidence["legacyOnDeviceCapability"]=recognizer.supportsOnDeviceRecognition && recognizer.isAvailable
        }
        let availability=LanguageAvailability()
        var translations=[[String:Any]]()
        for (from,to,source) in [("en","zh-Hans","The blue bicycle"),("zh-Hans","en","蓝色的自行车")] {
            let a=Locale.Language(identifier:from),b=Locale.Language(identifier:to)
            let status=await availability.status(from:a,to:b)
            var row:[String:Any]=["from":from,"to":to,"status":language(status),"inputSHA256":digest(source)]
            if status == .installed {
                do {
                    let response=try await TranslationSession(installedSource:a,target:b).translate(source)
                    row["localResultSHA256"]=digest(response.targetText);row["nonempty"]=(!response.targetText.isEmpty)
                } catch { row["localTranslation"]="unknown" }
            }
            translations.append(row)
        }
        evidence["translation"]=translations
        evidence["dictionary"]=["bicycle","自行车"].map { word -> [String:Any] in
            let range=DCSGetTermRangeInString(nil,word as CFString,0)
            guard range.location>=0,range.length>0,range.location+range.length<=word.utf16.count,
                  let def=DCSCopyTextDefinition(nil,word as CFString,range)?.takeRetainedValue() as String?,!def.isEmpty else {
                return ["fixture":word,"definitionAvailable":false]
            }
            return ["fixture":word,"definitionAvailable":true,"definitionSHA256":digest(def),"characters":def.count,
                    "containsRequestedChineseMeaning":def.contains("自行车") || def.contains("單車") || def.contains("自行車")]
        }
        evidence["modelInstallRequests"]=0; evidence["cloudASRRequests"]=0; evidence["audioDeviceOpens"]=0
        FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject:evidence,options:[.prettyPrinted,.sortedKeys])+Data([10]))
    }
}
