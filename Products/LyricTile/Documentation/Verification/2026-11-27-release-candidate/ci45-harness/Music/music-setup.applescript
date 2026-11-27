tell application "Music"
        set sound volume to 0
        set testPlaylist to make new user playlist with properties {name:"LyricTile Cloud Acceptance 46009188167"}
        add POSIX file "/Users/runner/work/nearpane/nearpane/Products/LyricTile/dist/evidence/real-music/original-chimes.wav" to testPlaylist
        add POSIX file "/Users/runner/work/nearpane/nearpane/Products/LyricTile/dist/evidence/real-music/original-chimes-reprise.wav" to testPlaylist
        set shuffle enabled to false
        set song repeat to off
        set firstTrack to item 1 of (tracks of testPlaylist)
        set secondTrack to item 2 of (tracks of testPlaylist)
        play testPlaylist
        delay 2
        set firstTitle to name of firstTrack as string
        set firstID to persistent ID of firstTrack as string
        set firstDuration to duration of firstTrack as string
        set firstLocation to get location of firstTrack
        set secondTitle to name of secondTrack as string
        set secondID to persistent ID of secondTrack as string
        set secondDuration to duration of secondTrack as string
        set secondLocation to get location of secondTrack
        set actualState to player state as string
        set actualPosition to player position as string
        set actualID to persistent ID of current track as string
    end tell
    -- Resolve the remote location properties before asking AppleScript for
    -- their POSIX paths. Music does not evaluate a nested POSIX-path specifier.
    set firstPath to POSIX path of firstLocation
    set secondPath to POSIX path of secondLocation
    return firstTitle & tab & firstID & tab & firstDuration & tab & firstPath & tab & secondTitle & tab & secondID & tab & secondDuration & tab & secondPath & tab & actualState & tab & actualPosition & tab & actualID