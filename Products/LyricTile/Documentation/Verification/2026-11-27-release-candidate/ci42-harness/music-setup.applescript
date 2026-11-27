tell application "Music"
        set sound volume to 0
        set testPlaylist to make new user playlist with properties {name:"LyricTile Cloud Acceptance 45997411802"}
        add POSIX file "/Users/runner/work/nearpane/nearpane/Products/LyricTile/dist/evidence/real-music/original-chimes.wav" to testPlaylist
        add POSIX file "/Users/runner/work/nearpane/nearpane/Products/LyricTile/dist/evidence/real-music/original-chimes-reprise.wav" to testPlaylist
        set shuffle enabled to false
        set song repeat to off
        set firstTrack to item 1 of (tracks of testPlaylist)
        set secondTrack to item 2 of (tracks of testPlaylist)
        play testPlaylist
        delay 2
        return (name of firstTrack) & tab & (persistent ID of firstTrack) & tab & (duration of firstTrack as string) & tab & (POSIX path of (location of firstTrack)) & tab & (name of secondTrack) & tab & (persistent ID of secondTrack) & tab & (duration of secondTrack as string) & tab & (POSIX path of (location of secondTrack)) & tab & (player state as string) & tab & (player position as string) & tab & (persistent ID of current track)
    end tell