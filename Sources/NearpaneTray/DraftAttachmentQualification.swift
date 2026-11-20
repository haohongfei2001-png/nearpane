#if NEARPANE_DRAFT_QUALIFICATION
  import Foundation
  import RiftletAdapters
  import RiftletCore

  /// Built only into the isolated qualification profile. The ordinary Host never opts into synthetic input.
  enum DraftAttachmentQualification {
    static func route(browserID: String, selectedURL: URL) throws -> DraftQualificationRoute {
      guard let surface = DraftCapability.route(browserID: browserID, url: selectedURL),
        let browser = AttachmentBrowser(rawValue: surface.browser.rawValue),
        let service = QualificationDraftService(rawValue: surface.service.rawValue)
      else { throw WebAdapterError.invalidTarget }
      let route = DraftQualificationRoute(browser: browser, service: service)
      guard route.permits(url: selectedURL.absoluteString) else {
        throw WebAdapterError.invalidTarget
      }
      return route
    }
    static func adapter(
      _ route: DraftQualificationRoute, media: URL, executor: any WebBridgeExecutor
    ) throws
      -> WebAttachmentAdapter
    {
      WebAttachmentAdapter(
        mediaDirectory: media, executor: executor, program: try route.program(),
        mode: .syntheticDevelopment,
        profile: route.profile, polling: .init(timeout: 0.55, interval: 0.05))
    }
  }
#endif
