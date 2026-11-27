tell application "Music"
        set sound volume to 0
        set testPlaylist to make new user playlist with properties {name:"LyricTile Cloud Acceptance 46016001883"}
        add POSIX file "/Users/runner/work/nearpane/nearpane/Products/LyricTile/dist/evidence/real-music/original-chimes.wav" to testPlaylist
        add POSIX file "/Users/runner/work/nearpane/nearpane/Products/LyricTile/dist/evidence/real-music/original-chimes-reprise.wav" to testPlaylist
        set firstTrack to missing value
        set secondTrack to missing value
        set importsReady to false
        set lastImportError to "The playlist does not yet contain two readable file tracks."
        set lastImportErrorNumber to 10001
        set importDeadline to (current date) + 12
        repeat
            try
                with timeout of 2 seconds
                    -- Resolve a fresh concrete list; do not carry unevaluated
                    -- item references across play, which changes Music state.
                    set importedTracks to get file tracks of testPlaylist
                    set lastImportErrorNumber to 10001
                    set lastImportError to "The playlist does not yet contain two readable file tracks."
                    if (count of importedTracks) is 2 then
                        set firstTrack to get item 1 of importedTracks
                        set secondTrack to get item 2 of importedTracks
                        set firstTitle to (get name of firstTrack) as string
                        set firstID to (get persistent ID of firstTrack) as string
                        set firstDuration to (get duration of firstTrack) as real
                        set firstLocation to get location of firstTrack
                        set secondTitle to (get name of secondTrack) as string
                        set secondID to (get persistent ID of secondTrack) as string
                        set secondDuration to (get duration of secondTrack) as real
                        set secondLocation to get location of secondTrack
                        if firstTitle is not "" and secondTitle is not "" and firstTitle is not secondTitle and firstID is not "" and secondID is not "" and firstID is not secondID and firstDuration > 0 and secondDuration > 0 and firstLocation is not missing value and secondLocation is not missing value and firstLocation is not secondLocation then
                            set importsReady to true
                            exit repeat
                        end if
                    end if
                end timeout
            on error importMessage number importNumber
                set lastImportError to importMessage & " (" & importNumber & ")"
                set lastImportErrorNumber to importNumber
                if importNumber is -1743 or importNumber is -600 then error importMessage number importNumber
            end try
            if (current date) >= importDeadline then exit repeat
            delay 0.25
        end repeat
        if not importsReady then
            if lastImportErrorNumber is -1712 then error lastImportError number -1712
            error ("LyricTile harness: two distinct imported file tracks were not readable within the bound. " & lastImportError) number 10001
        end if
    end tell
    -- Materialize locations outside Music before changing playback context.
    set firstPath to POSIX path of firstLocation
    set secondPath to POSIX path of secondLocation
    tell application "Music"
        set shuffle enabled to false
        set song repeat to off
        play testPlaylist
        delay 2
        set actualState to player state as string
        set actualPosition to player position as string
        set actualID to persistent ID of current track as string
    end tell
    return firstTitle & tab & firstID & tab & (firstDuration as string) & tab & firstPath & tab & secondTitle & tab & secondID & tab & (secondDuration as string) & tab & secondPath & tab & actualState & tab & actualPosition & tab & actualID