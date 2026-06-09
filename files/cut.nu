use ../scripts/_vid.nu *
use ../scripts/_path.nu *

def inputbox [ title, text, default ] {
    powershell -Command $"
        Add-Type -AssemblyName Microsoft.VisualBasic;
        [Microsoft.VisualBasic.Interaction]::InputBox\('($title)', '($text)', '($default)')
    "
}

# Semi-deprecated nvenc cutting tool because Discord supports av1 and that's much better
def main [ file: string ] {
    let start = inputbox start time 0 | default -e '0'
    let end = inputbox end time 0 | default -e '0'

    # Why h264? I think some iphones failed to watch videos on discord at some point
    vcut $file $start $end 50mib --codec h264_nvenc

    print $"($start) ($end)"
}

# Cuts a video from `start` to `end`, in nvenc p7 h265, with optional size target
def vcut [
    path: string
    start: string = "0"
    end: string = "1000000"
    size?: filesize
    result?: string
    --audio: filesize
    --crf: int = 30 # Lower this for better quality, 21 is much better, much bigger; not useful for target sizes
    --max: int = 1080 # Lower this if nvenc really can't make it fit in `size`
    --rawtime # Use -to timestamp instead of calculating -t from parsing $end - $start
    --codec: string = hevc_nvenc
] {
    let outpath = $result | default (path interject $path cut --count --ext mp4)

    let end = if $end == "0" {
        "1000000"
    } else {
        $end
    }

    let meta = vid get-meta $path
    let total_duration = $meta.duration | into int | $in / 1000000000

    # We gotta parse them because we can't rely on vid get-meta for the duration after cut
    # And doing a temp --copy cut is meh, dirty?
    let start_time = parse-time $start
    let end_time = [(parse-time $end), $total_duration] | math min
    let duration = $end_time - $start_time

    mut audio_bitrate = ($audio | default 96kb) | into int

    mut bitrate_flags = []
    if $size != null {
        let filesize_bits = ($size | into int) * 8 # Total bits
        let total_bitrate = ($filesize_bits / $duration) | into int

        # Audio can take a hit on the excellent opus codec
        $audio_bitrate = if $audio != null {
            $audio | into int
        } else if $total_bitrate > 96kb / 1b * 10 {
            $audio_bitrate
        } else if $total_bitrate > 96kb / 1b * 5 {
            print $"bumped audio down to 64k \(max (96kb * 10), at ($total_bitrate * 1b))"
            64kb | into int
        } else {
            print $"bumped audio down to 32k \(max (96kb * 5), at ($total_bitrate * 1b))"
            32kb | into int
        }

        let video_bitrate = $total_bitrate - $audio_bitrate

        const target_fallibility = 0.95
        const max_fallibility = 0.97

        $bitrate_flags ++= [-b:v ($video_bitrate * $target_fallibility)]
        $bitrate_flags ++= [-maxrate ($video_bitrate * $max_fallibility)]
        # $bitrate_flags ++= [-bufsize ($video_bitrate * 2)]
    }

    let scale = vid get-default-scaling $path --max=$max

    let audio_flags = if $audio_bitrate == 0b {
        ['-an']
    } else {
        [
            -c:a libopus
            -b:a $audio_bitrate
        ]
    }

    print $"start: ($start) end: ($end) duration: ($duration)"

    (ffmpeg
        -v warning
        -stats
        # Conditionally including -ss helps with hard-to-seek video formats (like avi)
        ...(if $start != "0" { [-ss $start] } else { [] })
        # -to inserted before video input if raw, -t inserted after if not
        ...(if $rawtime { [-to $end] } else { [] })
        -i $path
        ...(if not $rawtime { [-t $duration] } else { [] })
        -c:v $codec
        -preset p7
        -rc vbr
        ...($bitrate_flags)
        # -bufsize 1000k
        -cq $crf
        -profile:v main # Discord mobile & desktop sometimes fail on main10, on different videos. TODO: investigate
        -pix_fmt yuv420p # Force 8-bit profile even for 10 bit input streams
        -rc-lookahead 32
        -spatial-aq 1
        -aq-strength 15
        -temporal-aq 1
        -bf 4
        -g 300
        -vf $"scale=($scale.max_width):($scale.max_height)"
        ...($audio_flags)
        $outpath
    )

    # (ffmpeg
    #     -v warning
    #     -stats
    #     -ss $start
    #     -to $end
    #     -i $path
    #     ...($bitrate_flags)
    #     -c:v libx265
    #     -preset medium
    #     -crf $crf
    #     -x265-params "rc-lookahead=32:aq-mode=1:aq-strength=1:bframes=4:keyint=300"
    #     -vf $"scale=($scale.max_width):($scale.max_height)"
    #     ...($audio_flags)
    #     $outpath
    # )
}

# ChatGPT'd, it makes strange design decisions. It also thought we had destructuring T_T
def parse-time [input: string] {
    let mf = (
        if $input =~ '\.' {
            $input | split row '.'
        } else {
            [$input, '0']
        }
    )

    let parts = $mf.0 | split row ':' | reverse
    let seconds = ($parts.0 | into int)
    let minutes = (if ($parts | length) > 1 { $parts.1 | into int } else { 0 })
    let hours   = (if ($parts | length) > 2 { $parts.2 | into int } else { 0 })

    # Millis are aligned left, not right
    let millis = ($mf.1 | fill -w 3 -c 0 -a l | into int)

    $hours * 3600 + $minutes * 60 + $seconds + $millis / 1000
}
