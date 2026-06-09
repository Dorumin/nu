use ../scripts/_vid.nu *
use ../scripts/_dev.nu *
use ../scripts/_sqlite.nu *
use ../scripts/_combinators.nu *
use ../scripts/_forms.nu *

const CURRENT_PATH = path self

# Attach on postinit so TextChanged doesn't fire when initializing the default value
let arrow_code = open ($CURRENT_PATH | path dirname | path join timecb.ps1)

def update-screencap [ path: string, time: string, preview_path: string ] {
    # NOTE: for -ss, this will include the captured frame. For -to, it will **not**
    ffmpeg -ss $time -i $path -frames:v 1 -update 1 -y $preview_path o+e>| ignore
}

# tested on 6:52 65mib 24fps 1080p 9911 frames video
# | p  |   ssim   |   time    | fps |
# | -- | -------- | --------- | --- |
# | 13 | 0.993780 | 1m 8.9s   | 145 |
# | 12 | 0.993777 | 1m 8.2s   | 145 |
# | 11 | 0.993777 | 1m 8.8s   | 145 |
# | 10 | 0.993774 | 1m 9.5s   | 143 | 2-pass 1080p runtime plateau (~500fps 1st + ~200fps 2nd)
# |  9 | 0.994713 | 1m 26.1s  | 114 | Significantly reduced spurious blocking
# |  8 | 0.995800 | 2m 13.0s  | 74  | Starts matching precise target birate (250fps 1st pass), solid and quick
# |  7 | 0.996164 | 3m 1.8s   | 54  |
# |  6 | 0.996476 | 4m 31.5s  | 36  | 5-6 are my preferred middlegrounds
# |  5 | 0.996712 | 6m 3.1s   | 27  |
# |  4 | 0.996923 | 9m 26.7s  | 17  | Good threshold for low bitrates and lower resolutions, slowest I'd go at 1080p
# |  3 | 0.997030 | 17m 42.3s | 9.3 |
# |  2 | 0.997160 | 37m 13.5s | 4.4 |
# |  1 | 0.997313 | 75m 22.4s | 2.1 | Probably as low as you want to go (at lower resolutions), but...
# |  0 | 0.997390 | 196m 54s  | 0.8 | preset 0 can still improve color accuracy and moving shapes
def main [ file: string ] {
    let paths = collate $file --wait 350ms --interval 55ms | sort-by value -i

    let db_path = $nu.temp-dir | path join cutav1.db
    let timecode_path = $nu.temp-dir | path join modal_timecode.txt
    let preview_path = $nu.temp-dir | path join modal_preview.jpg

    sqlite init $db_path [
        "
            CREATE TABLE IF NOT EXISTS key_values (
                key TEXT PRIMARY KEY,
                value TEXT
            )
        "
    ]

    if ($paths | is-empty) {
        return
    }

    let lastconf = open $db_path | query db "SELECT * FROM key_values" | transpose -rd

    let defaults = if ($paths | length) != 1 or $lastconf.path? != ($paths.0.value | path expand) {
        {}
    } else {
        $lastconf
    }

    if ($paths | length) == 1 {
        update-screencap $paths.0.value ($defaults.start? | default 0 | into string) $preview_path
    }

    $env.config.filesize.unit = 'binary'

    let xy = parallel [
        { $paths.value | par-each { |path| ls -D $path | get 0.size } }
        { $paths.value | par-each { |path| vid get-meta $path } }
    ]
    let stats = $xy.0
    let metas = $xy.1
    let max_filesize = $stats | math max
    let max_duration = $metas.duration | math max
    let title = if ($paths | length) > 1 {
        $"AV1 \(($paths | length) videos)"
    } else {
        "AV1"
    }

    let watcher_id = job spawn {
        touch $timecode_path

        watch -q $timecode_path | reduce -f null { |_, last|
            try {
                let lines = open $timecode_path | decode utf-8 | lines | str trim
                let timecode = $lines.0?
                let path = $lines.1?

                if $timecode == $last {
                    return $last
                }

                print $timecode
                update-screencap $paths.0.value $timecode $preview_path

                return $timecode
            } catch { |e|
                print -e $e

                return null
            }
        }
    }

    let formatted_duration = vid _format-duration $max_duration

    let responses = (ps-form
        --title $title
        --options {
            preinit: $"$VIDEO_END = '($formatted_duration)'"
        }
        --questions [
            (if ($paths | length) == 1 {
                {
                    key: 'preview',
                    type: 'picture'
                }
            }),
            {
                type: 'row-start'
            },
            {
                key: 'start',
                type: 'text',
                label: 'Start time',
                default: ($defaults.start? | default '0:00'),
                autofocus: true,
                width: 134,
                postinit: ($arrow_code | str replace -a "__key__" "start")
            },
            {
                key: 'end',
                type: 'text',
                label: 'End time (excl. frame)',
                default: ($defaults.end? | default $formatted_duration), # '1:00:00'
                width: 134,
                postinit: ($arrow_code | str replace -a "__key__" "end")
            },
            {
                type: 'row-end'
            },
            {
                key: 'size',
                type: 'number',
                label: 'Target size in MB',
                # todo: instead of this, could store the last target size and use that
                default: ($defaults.size? | default (if $max_filesize < 50mib { 10 } else { 50 })),
                step: 1,
                decimals: 1,
                max: 10000,
                preinit: $'$videoLengthSec = ($max_duration / 1sec)',
                postnew: '$sizeNumeric.Add_TextChanged({ $sizeLabel.Text = "Target size in MB ($([Math]::Round($sizeNumeric.Value * 1024 * 1024 * 8 / $videoLengthSec / 1000, 1))kbit)" })'
            },
            {
                key: 'preset',
                type: 'number',
                label: 'Encoder preset',
                default: ($defaults.preset? | default 8),
                max: 12
            },
            {
                type: 'row-start'
            },
            {
                key: 'maxres',
                type: 'number',
                label: 'Max res',
                default: ($defaults.maxres? | default 1080),
                width: 134,
                max: (1080 * 8)
            },
            {
                key: 'keyint',
                type: 'number',
                label: 'Keyframe interval',
                width: 134,
                default: ($defaults.keyint? | default 289),
                max: 10000
            },
            {
                type: 'row-end'
            },
        ]
    )

    if $responses == null {
        return
    }

    let defaultend = get-param-default "vid 2p av1" end

    let start = $responses.start
    let end = if $responses.end == $formatted_duration {
        $defaultend
    } else {
        $responses.end
    }
    let size = $responses.size * 1mib
    let preset = $responses.preset
    let maxres = $responses.maxres
    let keyint = $responses.keyint

    let endstr = if $end == $defaultend {
        ':END:'
    } else {
        $end
    }

    print $"Svt av1 encoding at preset ($preset) targeting ($size | into string) from ($start) to ($endstr)"

    open $db_path | query db "REPLACE INTO key_values (key, value) VALUES (?, ?)" -p ['start', $start]
    open $db_path | query db "REPLACE INTO key_values (key, value) VALUES (?, ?)" -p ['end', $responses.end]
    open $db_path | query db "REPLACE INTO key_values (key, value) VALUES (?, ?)" -p ['size', $responses.size]
    open $db_path | query db "REPLACE INTO key_values (key, value) VALUES (?, ?)" -p ['preset', $preset]
    open $db_path | query db "REPLACE INTO key_values (key, value) VALUES (?, ?)" -p ['maxres', $maxres]
    open $db_path | query db "REPLACE INTO key_values (key, value) VALUES (?, ?)" -p ['keyint', $keyint]

    for path in $paths.value {
        open $db_path | query db "REPLACE INTO key_values (key, value) VALUES (?, ?)" -p ['path', ($path | path expand)]

        vid 2p av1 $path $size --start $start --end $end --preset $preset --count --max $maxres --keyint $keyint --ignoremin
    }
}
