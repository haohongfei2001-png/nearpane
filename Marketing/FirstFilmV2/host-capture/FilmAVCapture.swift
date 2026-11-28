import AppKit
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import Foundation

// A serial sample-buffer sink. No product UI is drawn here.
final class CaptureSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let writer: AVAssetWriter
    let video: AVAssetWriterInput
    let audio: AVAssetWriterInput
    let queue=DispatchQueue(label:"nearpane.film.capture")
    let output: URL
    var firstPTS: CMTime?
    var firstVideoUptime: Double?
    var videoFrames=0
    var audioBuffers=0
    var lastPTS: CMTime?
    var lastAudioPTS: CMTime?
    var frameStatuses:[String:Int]=[:]
    var rejectedNonIncreasingVideo=0
    var rejectedNonIncreasingAudio=0
    var firstAppendFailure=false
    var sampleLedger:FileHandle?
    init(output: URL,width: Int,height: Int) throws {
        self.output=output
        writer=try AVAssetWriter(outputURL:output,fileType:.mov)
        // Preserve indexed native fragments during long idle desktop intervals.
        // This changes only the container; sample PTS and pixels stay original.
        writer.movieFragmentInterval=CMTime(seconds:1,preferredTimescale:600)
        video=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,
            AVVideoWidthKey:width,AVVideoHeightKey:height,
            AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:38_000_000,AVVideoMaxKeyFrameIntervalKey:30]])
        video.expectsMediaDataInRealTime=true
        audio=AVAssetWriterInput(mediaType:.audio,outputSettings:[AVFormatIDKey:kAudioFormatMPEG4AAC,
            AVSampleRateKey:48000,AVNumberOfChannelsKey:2,AVEncoderBitRateKey:256000])
        audio.expectsMediaDataInRealTime=true
        super.init()
        writer.add(video);writer.add(audio)
        let ledger=output.deletingLastPathComponent().appendingPathComponent("capture-sample-pts.jsonl")
        FileManager.default.createFile(atPath:ledger.path,contents:nil)
        sampleLedger=try FileHandle(forWritingTo:ledger)
    }
    func ledger(_ type:String,_ pts:CMTime) {
        if let bytes=("{\"type\":\""+type+"\",\"pts\":"+String(pts.seconds)+"}\n").data(using:.utf8) { try? sampleLedger?.write(contentsOf:bytes) }
    }
    func appendFailure(_ type:String,_ pts:CMTime) {
        guard !firstAppendFailure else { return }
        firstAppendFailure=true
        save(["type":type,"pts":pts.seconds,"uptime":ProcessInfo.processInfo.systemUptime,
              "writerStatus":writer.status.rawValue,"writerError":writer.error.map(String.init(describing:)) ?? ""],name:"capture-first-append-failure.json")
    }
    func stream(_ stream: SCStream,didOutputSampleBuffer sample: CMSampleBuffer,of type:SCStreamOutputType) {
        guard sample.isValid,writer.status == .writing else { return }
        let pts=sample.presentationTimeStamp
        guard pts.isValid,pts.seconds.isFinite else { return }
        if type == .screen {
            // Apple's ScreenCaptureKit sample explicitly processes only .complete
            // frames. Idle/blank/stopped events are notifications, not new frames.
            guard let attachmentsArray=CMSampleBufferGetSampleAttachmentsArray(sample,createIfNecessary:false) as? [[SCStreamFrameInfo:Any]],
                  let attachments=attachmentsArray.first,
                  let status=attachments[.status] as? Int else { return }
            frameStatuses[String(status),default:0]+=1
            guard status == SCFrameStatus.complete.rawValue,CMSampleBufferGetImageBuffer(sample) != nil else { return }
            if let lastPTS,pts <= lastPTS { rejectedNonIncreasingVideo+=1;return }
            if firstPTS == nil {
                firstPTS=pts;firstVideoUptime=ProcessInfo.processInfo.systemUptime
                writer.startSession(atSourceTime:pts)
                save(["firstVideoPTS":pts.seconds,"firstVideoUptime":firstVideoUptime!,"unixTime":Date().timeIntervalSince1970],name:"capture-first-frame.json")
            }
            if video.isReadyForMoreMediaData {
                if video.append(sample) { videoFrames+=1;lastPTS=pts;ledger("video",pts) }
                else { appendFailure("video",pts) }
            }
        } else if type == .audio,let firstPTS,pts >= firstPTS,audio.isReadyForMoreMediaData {
            if let lastAudioPTS,pts <= lastAudioPTS { rejectedNonIncreasingAudio+=1;return }
            if audio.append(sample) { audioBuffers+=1;lastAudioPTS=pts;ledger("audio",pts) }
            else { appendFailure("audio",pts) }
        }
    }
    func stream(_ stream:SCStream,didStopWithError error:Error) {
        save(["error":String(describing:error)],name:"capture-stream-error.json")
    }
    func save(_ data:[String:Any],name:String) {
        if let bytes=try? JSONSerialization.data(withJSONObject:data,options:[.prettyPrinted,.sortedKeys]) {
            try? bytes.write(to:output.deletingLastPathComponent().appendingPathComponent(name),options:.atomic)
        }
    }
}

@main struct FilmAVCapture {
    static func main() async throws {
        let args=CommandLine.arguments
        guard args.count==4,let displayID=UInt32(args[1]),let seconds=Double(args[2]),seconds>0,seconds<=300 else { exit(2) }
        let output=URL(fileURLWithPath:args[3])
        let content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:false)
        guard let display=content.displays.first(where:{$0.displayID == displayID}) else { exit(3) }
        let mode=CGDisplayCopyDisplayMode(displayID)!
        let sink=try CaptureSink(output:output,width:mode.pixelWidth,height:mode.pixelHeight)
        let config=SCStreamConfiguration()
        config.width=mode.pixelWidth;config.height=mode.pixelHeight
        config.minimumFrameInterval=CMTime(value:1,timescale:30)
        config.queueDepth=8;config.showsCursor=true
        config.capturesAudio=true;config.excludesCurrentProcessAudio=true
        config.sampleRate=48000;config.channelCount=2
        let stream=SCStream(filter:SCContentFilter(display:display,excludingApplications:[],exceptingWindows:[]),configuration:config,delegate:sink)
        try stream.addStreamOutput(sink,type:.screen,sampleHandlerQueue:sink.queue)
        try stream.addStreamOutput(sink,type:.audio,sampleHandlerQueue:sink.queue)
        guard sink.writer.startWriting() else { throw sink.writer.error! }
        try await stream.startCapture()
        sink.save(["startUptime":ProcessInfo.processInfo.systemUptime,"unixTime":Date().timeIntervalSince1970,
            "displayID":displayID,"width":mode.pixelWidth,"height":mode.pixelHeight,"requestedFPS":30,
            "cursorIncluded":true,"systemAudioRequested":true,"durationRequested":seconds],name:"capture-started.json")
        let deadline=ProcessInfo.processInfo.systemUptime+seconds
        while ProcessInfo.processInfo.systemUptime<deadline {
            if let stop=ProcessInfo.processInfo.environment["FILM_CAPTURE_STOP_FILE"],FileManager.default.fileExists(atPath:stop) { break }
            try await Task.sleep(nanoseconds:100_000_000)
        }
        do { try await stream.stopCapture() }
        catch { sink.save(["error":String(describing:error)],name:"capture-stop-error.json") }
        await withCheckedContinuation { continuation in
            sink.queue.async {
                sink.video.markAsFinished();sink.audio.markAsFinished()
                sink.writer.finishWriting { continuation.resume() }
            }
        }
        try? sink.sampleLedger?.close()
        sink.save(["frameStatuses":sink.frameStatuses,"nonIncreasingVideoSamplesIgnored":sink.rejectedNonIncreasingVideo,
            "nonIncreasingAudioSamplesIgnored":sink.rejectedNonIncreasingAudio,"completeFramesOnly":true,"fragmentSeconds":1,
            "videoFrames":sink.videoFrames,"audioBuffers":sink.audioBuffers,
            "firstPTS":sink.firstPTS?.seconds ?? -1,"lastPTS":sink.lastPTS?.seconds ?? -1,
            "writerStatus":sink.writer.status.rawValue,"writerError":sink.writer.error.map(String.init(describing:)) ?? "",
            "capture":"Actual ScreenCaptureKit/WindowServer desktop and system audio; no synthetic UI or interpolated product frames"],name:"capture-completed.json")
        guard sink.writer.status == .completed else { exit(4) }
    }
}
