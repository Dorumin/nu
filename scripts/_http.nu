export def 'http fetch-chunks' [
    urls: list
    --threads: int = 8
] {
    $urls | enumerate | par-each --keep-order --threads $threads { |elem|
        let index = $elem.index
        let url = $elem.item

        loop {
            try {
                print -e $"fetch chunk ($index)"
                let buf = http get --raw $url
                return $buf
            } catch { |e|
                print -e $"(ansi red)chunk ($index) failed, sleep and retry(ansi reset)"
                sleep 1sec
            }
        }
    }
}

export def 'steam url' [
    interface: string
    method: string
    version: int
    params: record
] {
    $"https://api.steampowered.com/($interface)/($method)/v($version)/?" + ($params | insert key $env.STEAM_KEY | url build-query)
}

export def 'steam app-achievements' [
    appid: int
] {
    http get (steam url ISteamUserStats GetGlobalAchievementPercentagesForApp 2 { gameid: $appid })
}


export def 'steam user-achievements' [
    userid: int
    appid: int
] {
    http get (steam url ISteamUserStats GetPlayerAchievements 1 { steamid: $userid, appid: $appid })
}
