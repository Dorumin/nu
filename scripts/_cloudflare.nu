use _combinators.nu *
use _mutex.nu *

const CREATE_CAPTURE_STMT = "
    CREATE TABLE IF NOT EXISTS cloudflare_url_capture (
        key TEXT PRIMARY KEY,
        captured BOOLEAN NOT NULL
    )
"
const INSERT_CAPTURE_STMT = "
    REPLACE INTO cloudflare_url_capture (key, captured)
    VALUES (?, true)
"

export def cloudflare [ port ] {
    try {
        # TODO: Why try?
        stor open | query db $CREATE_CAPTURE_STMT
    }

    let key = random chars

    stor insert -t cloudflare_url_capture -d { key: $key, captured: false }

    cloudflared tunnel --url $"http://localhost:($port)" o+e>| each { |chunk|
        let urlmatch = $chunk | parse -r '(?<url>https://.+?\.trycloudflare.com)'

        $urlmatch | each { |match|
            let captured = stor open | query db "SELECT * FROM cloudflare_url_capture WHERE key = ?" -p [$key]
            let captured = $captured.0.captured | into bool

            if not $captured {
                print $"CLOUDFLARE: Found url, copying: ($match.url)"
                $match.url | bp

                stor open | query db $INSERT_CAPTURE_STMT -p [$key]
            }
        }

        print -en $chunk
    }
}

export def 'cloudflare update' [] {
    let path = which cloudflared | first | get path

    let url = 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe'

    http get --raw $url | save -f $path
}

export def cloudshare [] {
    let portex = mutex make

    (parallel
        {
            sserver o+e>| each { |chunk|
                $chunk | parse -r '(?:localhost|\d+\.\d+\.\d+\.\d+):(?<port>\d+)' | each { |match|
                    mutex with $portex { |guard, prev|
                        mutex set $guard ($match.port | into int)
                    }
                }
            }
            # python -m http.server
        }
        {
            mut port = 0
            loop {
                let found = mutex with-get $portex

                if $found != null {
                    $port = $found
                    break
                }
            }

            cloudflare $port
        }
    )
}

export def cloudparty [] {
    parallel [
        { copyparty }
        { cloudflare 3923 }
    ]
}
