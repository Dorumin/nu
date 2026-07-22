use ../scripts/_vid.nu *
use ../scripts/_combinators.nu *
use ../scripts/_sqlite.nu *
use ../scripts/_forms.nu *

const CURRENT_PATH = path self

# Attach on postinit so TextChanged doesn't fire when initializing the default value
let arrow_code = open ($CURRENT_PATH | path dirname | path join timecb.ps1)

def update-screencap [
    path: string,
    time: string,
    preview_path: string,
    --crop: string
    --subtitles
] {
    mut filters = []

    if $crop != null {
        $filters ++= [$"crop=($crop)"]
    }

    if $subtitles {
        let escaped_path = $path | str replace -a '\' '/' | str replace ':' '\:'

        $filters ++= [$"subtitles='($escaped_path)':si=1"]
    }

    # NOTE: for -ss, this will include the captured frame. For -to, it will **not**
    let vfargs = if ($filters | is-not-empty) {
        [-vf ($filters | str join ",")]
    } else {
        []
    }

    # print $vfargs $subtitles $filters

    ffmpeg -ss $time -i $path -frames:v 1 -update 1 ...$vfargs -y $preview_path o+e>| ignore
}

def main [ file: string ] {
    let paths = collate $file --wait 350ms --interval 55ms | sort-by value -i

    if ($paths | is-empty) {
        return
    }

    let db_path = $nu.temp-dir | path join togif.db
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

    let lastconf = open $db_path | query db "SELECT * FROM key_values" | transpose -rd

    let defaults = if ($paths | length) != 1 or $lastconf.path? != $paths.0.value {
        {}
    } else {
        $lastconf
    }

    if ($paths | length) == 1 {
        (update-screencap
            $paths.0.value
            ($defaults.start? | default 0 | into string)
            $preview_path
            --crop $defaults.crop?
        )
    }

    let metas = $paths.value | par-each { |path| vid get-meta $path }
    let max_duration = $metas.duration | math max

    let max_width = $metas.width | math max
    let max_height = $metas.height | math max

    let formatted_duration = vid _format-duration $max_duration

    let watcher_id = job spawn {
        touch $timecode_path

        watch -q $timecode_path | reduce -f null { |_, last|
            try {
                let rawf = open $timecode_path | decode utf-8
                let lines = $rawf | lines | str trim
                let timecode = $lines.0?
                mut extra = null

                try {
                    $extra = $lines.1 | from json
                }

                # print $"raw: ($rawf)"

                if $timecode == null {
                    return $last
                }

                # Nushell doesn't have referential equality?
                if [$timecode $extra] == $last {
                    return $last
                }

                print $"time: ($timecode)"

                update-screencap $paths.0.value $timecode $preview_path --crop $extra.crop?

                return [$timecode $extra]
            } catch { |e|
                print -e $e

                return null
            }
        }
    }

    $env.config.filesize.unit = 'binary'
    let responses = (ps-form
        --title "Video to gif"
        --options {
            preinit: $'$VIDEO_END = "($formatted_duration)"; $VIDEO_PATH = "($paths.0.value)";',
            globals: {
                VIDEO_WIDTH: $max_width,
                VIDEO_HEIGHT: $max_height,
            }
        }
        --questions [
            (if ($paths | length) == 1 {
                {
                    key: 'preview',
                    type: 'picture',
                    postinit: `

$previewPictureBox.BackColor = [System.Drawing.Color]::Black
# $previewPictureBox.Width = [Math]::min(276, $previewPictureBox.Height * $VIDEO_HEIGHT / $VIDEO_WIDTH)

$startCoord = $null
$endCoord = $null

$previewPictureBox.Add_Paint({
    param($sender, $e)

    if ($startCoord -eq $null -or $endCoord -eq $null) {
        return
    }

    $minx = [Math]::min($startCoord.X, $endCoord.X)
    $maxx = [Math]::max($startCoord.X, $endCoord.X)
    $miny = [Math]::min($startCoord.Y, $endCoord.Y)
    $maxy = [Math]::max($startCoord.Y, $endCoord.Y)
    $dx = $maxx - $minx
    $dy = $maxy - $miny

    $g = $e.Graphics

    $translucentColor = [System.Drawing.Color]::FromArgb(75, 255, 255, 255) # Semi-transparent black

    $translucentBrush = New-Object System.Drawing.SolidBrush($translucentColor)

    $rect = New-Object System.Drawing.Rectangle($minx, $miny, $dx, $dy)

    $g.FillRectangle($translucentBrush, $rect)

    $translucentBrush.Dispose()
})

$previewPictureBox.Add_MouseDown({
    param($sender, $e)

    $script:startCoord = $e.Location

    Write-Log "down $($e.Location) $($previewPictureBox.Width) $($previewPictureBox.Height)"
})

$previewPictureBox.Add_MouseMove({
    param($sender, $e)

    $script:endCoord = $e.Location
})

$previewPictureBox.Add_MouseUp({
    param($sender, $e)

    if ($startCoord -eq $null) {
        return
    }

    $endCoord = $e.Location

    $pictureWidth = $previewPictureBox.Width
    $pictureHeight = $previewPictureBox.Height
    $offsetLeft = 0
    $offsetRight = 0

    if ($previewPictureBox.Image -ne $null) {
        $imageWidth = $previewPictureBox.Image.Width
        $imageHeight = $previewPictureBox.Image.Height

        # Calculate the smallest ratio to fit, then center it
        $widthRatio = $pictureWidth / $imageWidth
        $heightRatio = $pictureHeight / $imageHeight
        $scaleFactor = [Math]::Min($widthRatio, $heightRatio)

        $displayedWidth = [Math]::Round($imageWidth * $scaleFactor)
        $displayedHeight = [Math]::Round($imageHeight * $scaleFactor)

        # Overrides
        $offsetLeft = [Math]::Round(($pictureWidth - $displayedWidth) / 2)
        $offsetTop = [Math]::Round(($pictureHeight - $displayedHeight) / 2)
        $pictureWidth = $displayedWidth
        $pictureHeight = $displayedHeight
    }

    $minx = [Math]::min($startCoord.X - $offsetLeft, $endCoord.X - $offsetLeft)
    $maxx = [Math]::max($startCoord.X - $offsetLeft, $endCoord.X - $offsetLeft)
    $miny = [Math]::min($startCoord.Y - $offsetTop, $endCoord.Y - $offsetTop)
    $maxy = [Math]::max($startCoord.Y - $offsetTop, $endCoord.Y - $offsetTop)

    # Clamp when near the edges
    if ($minx -le 10) { $minx = 0 }
    if ($miny -le 10) { $miny = 0 }
    if ($maxx -gt ($pictureWidth - 10)) { $maxx = $pictureWidth }
    if ($maxy -gt ($pictureHeight - 10)) { $maxy = $pictureHeight }

    $dx = $maxx - $minx
    $dy = $maxy - $miny
    $top = $miny / $pictureHeight * $VIDEO_HEIGHT
    $left = $minx / $pictureWidth * $VIDEO_WIDTH
    $width = $dx / $pictureWidth * $VIDEO_WIDTH
    $height = $dy / $pictureHeight * $VIDEO_HEIGHT

    # Single clicks should reset the scaling
    if ($dx -eq 0 -or $dy -eq 0) {
        $top = 0
        $left = 0
        $width = $VIDEO_WIDTH
        $height = $VIDEO_HEIGHT
    }

    $top = [Math]::max($top, 0)
    $left = [Math]::max($left, 0)
    $width = [Math]::min($VIDEO_WIDTH - $left, $width)
    $height = [Math]::min($VIDEO_HEIGHT - $top, $height)

    $script:startCoord = $null
    $script:endCoord = $null

    $cropTextBox.Text = "$([Math]::round($width)):$([Math]::round($height)):$([Math]::round($left)):$([Math]::round($top))"
})
                    `
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
                label: 'End time',
                default: ($defaults.end? | default $formatted_duration), # '1:00:00'
                width: 134,
                postinit: ($arrow_code | str replace -a "__key__" "end")
            },
            {
                type: 'row-end'
            },
            {
                key: 'palette',
                type: 'dropdown',
                label: 'Palette type',
                options: [
                    { label: 'Global', value: 'global' },
                    { label: 'Per-frame', value: 'frame' }
                ],
                default: ($defaults.palette? | default 0)
            },
            {
                key: 'dithering',
                type: 'dropdown',
                label: 'Dithering (just use sierra2_4a or none)',
                options: [
                    { label: 'None', value: 'none' },
                    { label: 'Atkinson', value: 'atkinson' },
                    # Looks great for being basic, deterministic, and fast, but has obvious matrix pattern
                    # Only when viewed from afar, it's really gross when zoomed in
                    { label: 'Bayer', value: 'bayer' },
                    { label: 'Burkes', value: 'burkes' },
                    { label: 'Floyd/Steinberg', value: 'floyd_steinberg' },
                    { label: 'Heckbert', value: 'heckbert' }, # 'considered wrong', works pretty well
                    { label: 'Sierra2', value: 'sierra2' },
                    { label: 'Sierra2_4a', value: 'sierra2_4a' }, # ffmpeg default; good at its job
                    { label: 'Sierra3' value: 'sierra3' }
                ],
                default: ($defaults.dithering? | default 7)
            },
            {
                key: 'loops',
                type: 'number',
                label: 'Loop count (-1 = never, 0 = infinite)',
                default: ($defaults.loops? | default 0),
                min: -1,
                max: 65535
            },
            {
                key: 'maxres',
                type: 'number',
                label: 'Max res',
                default: ($defaults.maxres? | default 512),
                max: (1080 * 8)
            },
            {
                key: 'crop',
                type: 'text',
                label: 'Crop (w:h:x:y)',
                default: ($defaults.crop? | default $'($max_width):($max_height):0:0'),
                postinit: '
$cropTextBox.Add_TextChanged({
    param($sender, $e)

    Update-TimeCapture $startTextBox.Text
})
'
            }
        ]
    )

    if $responses == null {
        return
    }

    print $responses

    open $db_path | query db "REPLACE INTO key_values (key, value) VALUES (?, ?)" -p ['start', $responses.start]
    open $db_path | query db "REPLACE INTO key_values (key, value) VALUES (?, ?)" -p ['end', $responses.end]
    open $db_path | query db "REPLACE INTO key_values (key, value) VALUES (?, ?)" -p ['palette', $responses.palette_index]
    open $db_path | query db "REPLACE INTO key_values (key, value) VALUES (?, ?)" -p ['dithering', $responses.dithering_index]
    open $db_path | query db "REPLACE INTO key_values (key, value) VALUES (?, ?)" -p ['loops', $responses.loops]
    open $db_path | query db "REPLACE INTO key_values (key, value) VALUES (?, ?)" -p ['maxres', $responses.maxres]
    open $db_path | query db "REPLACE INTO key_values (key, value) VALUES (?, ?)" -p ['crop', $responses.crop]

    for path in $paths.value {
        open $db_path | query db "REPLACE INTO key_values (key, value) VALUES (?, ?)" -p ['path', $path]

        (vid to-gif $path
            --start $responses.start
            --end $responses.end
            --height $responses.maxres
            --loops $responses.loops
            --framepalettes=($responses.palette != 'global')
            --dither $responses.dithering
            --crop $responses.crop
        )
    }
}
