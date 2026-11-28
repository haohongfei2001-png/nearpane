    // Bounded camera path in the isolated copy only. SettingsView, registry,
    // lifecycle, real playback and screenshot intake remain production code.
    func filmV2HostScene(_ session:NativeAcceptanceSession) async throws {
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
              let outPath=ProcessInfo.processInfo.environment["FILM_V2_OUTPUT"],
              let lrcPath=ProcessInfo.processInfo.environment["FILM_V2_LRC"],
              let displayID=UInt32(ProcessInfo.processInfo.environment["NEARPANE_FILM_DISPLAY_ID"] ?? ""),
              let screen=NSScreen.screens.first(where:{($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID})
        else { throw CocoaError(.fileReadNoPermission) }
        let output=URL(fileURLWithPath:outPath,isDirectory:true)
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        func save(_ name:String,_ value:[String:Any]) {
            if let bytes=try? JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]) {
                try? bytes.write(to:output.appendingPathComponent(name),options:.atomic)
            }
        }
        if let wallpaper=ProcessInfo.processInfo.environment["FILM_V2_WALLPAPER"] {
            do { try NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath:wallpaper),for:screen,options:[.imageScaling:NSImageScaling.scaleProportionallyUpOrDown.rawValue]) }
            catch { save("wallpaper-error.json",["error":String(describing:error)]) }
        }
        // The owned empty profile was prepared by the existing executable-bound
        // acceptance entry. nil here selects normal real-player/tray operation,
        // not the verificationOnly snapshot route.
        let embedded=EmbeddedModules(support:session.support.appendingPathComponent("Nearpane"),testSession:nil,candidate:true)
        modules=embedded;connectManagementNavigation(embedded)
        let store=FileConfigurationStore(url:session.support.appendingPathComponent("Nearpane/host-configuration.json"))
        var config=try store.load()
        config.modules=BuiltinCatalog.productManifests.map { ModulePreference(id:$0.id,enabled:$0.id == BuiltinCatalog.lyrics || $0.id == BuiltinCatalog.screenshots) }
        let ordered=[BuiltinCatalog.lyrics,BuiltinCatalog.screenshots]
        config.modules.sort { (ordered.firstIndex(of:$0.id) ?? 99) < (ordered.firstIndex(of:$1.id) ?? 99) }
        try store.save(config)
        let host=embedded.makeHost(store:store,provider:UnavailableDesktopProvider())
        self.host=host
        await host.start();await embedded.voice.waitForTransition();await embedded.tray.connect()
        embedded.filmExposeRealSurfaces()
        guard let model=embedded.filmActualLyricsModel else { throw CocoaError(.featureUnsupported) }
        model.settings.onlineLyrics=false;model.settings.appearance = .light
        model.settings.completedWelcome=true
        model.selectPlayer(.appleMusic)
        updater=ApplicationUpdater(allowNetwork:false)
        settingsScreens.update(SystemScreens.geometry());settingsNavigation.showModules()
        showSettings()
        guard let management=settings?.window else { throw CocoaError(.validationMissingMandatoryProperty) }
        management.setFrame(NSRect(x:screen.frame.minX+120,y:screen.frame.maxY-112-740,width:1180,height:740),display:true)
        management.appearance=NSAppearance(named:.aqua)
        let size=FilmDualCards.photographySize(lyricsHeight:embedded.filmActualLyricsHeight,trayRows:embedded.tray.rowCount)
        let camera=NSPanel(contentRect:NSRect(origin:.zero,size:size),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        camera.isOpaque=false;camera.backgroundColor = .clear;camera.hasShadow=true
        camera.level = .floating;camera.hidesOnDeactivate=false;camera.acceptsMouseMovedEvents=true
        camera.contentView=NSHostingView(rootView:FilmDualCards(host:host,modules:embedded))
        camera.setFrame(NSRect(x:screen.frame.maxX-size.width-28,y:screen.frame.maxY-size.height-52,width:size.width,height:size.height),display:true)
        camera.orderFrontRegardless()
        save("dual-camera-geometry.json",[
            "sourceCommit":ProcessInfo.processInfo.environment["GITHUB_SHA"] ?? "unknown",
            "baseProductCommit":"d5767d87bc45245b31d0980e91e43778c5f424ed",
            "unreleasedArtworkFix":true,"displayID":displayID,
            "screenFrame":[screen.frame.minX,screen.frame.minY,screen.frame.width,screen.frame.height],
            "backingScale":screen.backingScaleFactor,"systemReduceMotion":NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "panelFrame":[camera.frame.minX,camera.frame.minY,camera.frame.width,camera.frame.height],
            "managementFrame":[management.frame.minX,management.frame.minY,management.frame.width,management.frame.height],
            "trayHeightAuthority":"LayoutComposer.compose(... trayRows: TrayModule.rowCount).screenshots.height",
            "canonicalEmptyAndFullTrayHeights":[FilmDualCards.canonicalTrayHeight(rows:1),FilmDualCards.canonicalTrayHeight(rows:2)],
            "photographyScale":280.0/208.0,"topAnchorPoints":52,"rightAnchorPoints":28,
            "pid":ProcessInfo.processInfo.processIdentifier,"emptyOwnedProfile":session.support.path
        ])
        var imported=false;var ready=false;var records:[[String:Any]]=[]
        for sample in 0..<6000 {
            if !imported,model.snapshot.selection != nil { imported=model.filmImportLocalLyrics(URL(fileURLWithPath:lrcPath)) }
            // One retained native hosting view, following the real row count.
            // Re-anchor only this photography window; no product UI animation,
            // screenshot state, or cell geometry is replaced or synthesized.
            let desired=FilmDualCards.photographySize(lyricsHeight:embedded.filmActualLyricsHeight,trayRows:embedded.tray.rowCount)
            let target=NSRect(x:screen.frame.maxX-desired.width-28,
                y:screen.frame.maxY-desired.height-52,width:desired.width,height:desired.height)
            if abs(camera.frame.height-target.height)>0.01 || abs(camera.frame.minY-target.minY)>0.01 || abs(camera.frame.minX-target.minX)>0.01 {
                camera.setFrame(target,display:true)
                camera.contentView?.layoutSubtreeIfNeeded()
            }
            let record:[String:Any]=[
                "sample":sample,"uptime":ProcessInfo.processInfo.systemUptime,"unixTime":Date().timeIntervalSince1970,
                "title":model.title,"player":model.snapshot.player?.rawValue ?? "none","state":String(describing:model.snapshot.state),
                "positionMS":model.playbackPositionMS as Any? ?? NSNull(),"currentCueIndex":model.currentCueIndex as Any? ?? NSNull(),
                "controlsVisible":model.controlsVisible,"artworkBytes":model.snapshot.artwork?.count ?? 0,
                "lyricsHeight":embedded.filmActualLyricsHeight,"trayConnected":embedded.tray.connected,
                "trayRowCount":embedded.tray.rowCount,
                "trayCanonicalHeight":FilmDualCards.canonicalTrayHeight(rows:embedded.tray.rowCount),
                "trayPhotographicHeight":FilmDualCards.canonicalTrayHeight(rows:embedded.tray.rowCount)*280.0/208.0,
                "photographyPanelFrame":[camera.frame.minX,camera.frame.minY,camera.frame.width,camera.frame.height],
                "trayVisibleIDs":embedded.tray.visibleIDs.map(\.uuidString),"trayIssue":embedded.tray.issue as Any? ?? NSNull(),
                "hostOrder":host.registry.preferences.filter(\.enabled).map(\.id),
                "frontmostBundleID":NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none",
                "managementVisible":management.isVisible,"cameraVisible":camera.isVisible
            ]
            records.append(record)
            if !ready,model.artwork != nil,model.leadCues.count>0,model.snapshot.state == .playing,embedded.tray.connected {
                ready=true;save("dual-ready.json",record)
            }
            if sample % 6 == 0 { save("dual-state.json",record) }
            if sample % 150 == 0 { save("dual-state-timeline.json",["samples":records]) }
            if FileManager.default.fileExists(atPath:output.appendingPathComponent("stop").path) { break }
            try? await Task.sleep(for:.milliseconds(33))
        }
        save("dual-state-timeline.json",["samples":records])
        save("dual-camera-scope.json",[
            "actualManagementWindow":true,"actualHostRegistry":true,"actualPlayback":true,"fixturePlayback":false,
            "actualTraySurface":true,"syntheticScreenshotAssets":false,
            "photographyOnly":"Equal 280pt photographic width and matched native popover glass. Riftlet height follows the production LayoutComposer/TrayModule rowCount (76pt empty,144pt with real screenshot) before uniform280/208 scaling. UI cells/icons/images are not vertically stretched. UI interior opacity unchanged.",
            "moduleOrderSource":"Production management-window dropDestination calls actual HostSession.moveModule; no desktop-card dragging is invented."
        ])
        camera.close();management.close();host.stop();await embedded.finishStopping()
    }
