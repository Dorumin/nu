use _combinators.nu *
use _dev.nu *
use _term.nu *
use _mutex.nu *
use _ssh.nu *
use _path.nu *
use _str.nu *

const NANOSECONDS_IN_SECOND = 1000000000

export def 'vid get-streams' [
    file_path: path
    ...xargs
] {
    let ffprobe_results = do {
        let res = ffprobe -v error -show_entries 'format:stream' ...$xargs $file_path | complete

        echo $res

        if ("stderr" in $res and $res.stderr != "") or $res.exit_code != 0 {
            print "Error or warnings while probing file."
            print $"Path: ($file_path)"
            print $"Exit code: ($res.exit_code)"
            print $"Stderr:\n($res.stderr)"
        }

        $res | get stdout
    }
    let sections = $ffprobe_results | parse -r '\[([A-Z]+?)\]([\s\S]*?)\[/\1\]' | rename section_name props | upsert props {
        $in | lines | str trim | where $it != "" | split column '=' key value | transpose -rd
    }

    $sections
}

export def 'vid get-meta' [
    file_path: path
    ...xargs
] {
    let streams = vid get-streams $file_path ...$xargs
    let format = $streams | where section_name == FORMAT | first | get props
    let video = $streams | where section_name == STREAM and props.codec_type == video | get 0?.props
    let dimensions = $streams | where { |r|
        $r.section_name == "STREAM" and "width" in $r.props and "height" in $r.props
    } | get 0?.props

    $format | select duration size bit_rate
        | upsert duration { try { into float | $in * 1sec } catch { null } }
        | upsert bit_rate { try { into filesize } catch { null } }
        | upsert size { into filesize }
        | then $dimensions { |dims|
            insert height ($dims.height | into int)
            | insert width ($dims.width | into int)
        }
        | then ($format | get -o "TAG:comment") { |comment| insert comment $comment }
        | then $video { |v|
            insert vcodec $v.codec_name
            | insert frames { |r|
                try {
                    return ($v.nb_frames | into int)
                }
                try {
                    return ($v.nb_read_frames | into int)
                }
                try {
                    # guesstimate
                    return ($r.duration / 1sec * 30 | math floor)
                }

                null
            }
            | insert fps { |r| try { $r.frames / ($r.duration / 1sec) } }
            | insert fps_ratio ($v.r_frame_rate | split row '/')
        }
}

export def 'vid audio-stream-size' [
    path: path
    --format: string = "matroska" # Container format to use (like ogg, mp3, adts, matroska). Matroska is very flexible
] {
    ffmpeg -v warning -i $path -vn -acodec copy -f $format - | length | into filesize
}

export def 'vid size-report' [
    --glob: string = "**/*.{mp4,webm,mkv,avi,m4v,mpg,wmv,flv,mov}",
    --min-per-ten: filesize = 0b
    --min-size: filesize = 0b
    --threads: int = 16
    --limit: int = 5000
    --audio
    --noaudio # Strip audio stream size when calculating file size/bitrate
    --raw
] {
    let results = glob $glob
        | par-each -t $threads { |path|
            vid get-meta $path
            | upsert size { |row|
                if $audio {
                    vid audio-stream-size $path
                } else if $noaudio {
                    try {
                        $row.size - (vid audio-stream-size $path)
                    } catch {
                        $row.size
                    }
                } else {
                    $row.size
                }
            }
            | upsert per_sec { |row| $row.size / ($row.duration | into int | $in / 1000000000) }
            | upsert per_ten { |row| $row.size / ($row.duration | into int | $in / 1000000000) * 600 }
            | upsert path { $path }
        }
        | sort-by per_ten
        | where per_ten >= $min_per_ten
        | where size >= $min_size
        | last $limit

    if $raw {
        $results
    } else {
        $results | each { |file|
            let parsed = $file.path | path parse
            print (
                $"(ansiwrap blue $parsed.parent)/(ansiwrap yellow ($file.path | path basename))\n" +
                $"Size: (ansiwrap light_green ($file.size | to text)) \(bitrate: (ansiwrap light_cyan ($file.per_sec * 8 / 1000000b | math round -p 2))mbit, " +
                # $"1sec: (ansiwrap light_cyan ($file.per_sec / 1000000b | math round -p 2))mb, " +
                $"10min: (ansiwrap light_cyan ($file.per_ten / 1000000b | math round -p 1))mb\)"
            )
        }
    }
}

export def 'vid get-default-scaling' [
    path: path,
    --max: int = 1080
    # -2 to scale to multiples of 2 for derived aspect ratio resolution
    # Used to return null, -2 is more convenient, and always defaulted to that
    # Keep this file clean if returned to null
    --dominant-sentinel = -2
    --expand
] {
    let meta = vid get-meta $path
    mut max_height = if $meta.width >= $meta.height {
        [$meta.height, $max] | math min
    } else {
        $dominant_sentinel
    }
    mut max_width = if $meta.height > $meta.width {
        [$meta.width, $max] | math min
    } else {
        $dominant_sentinel
    }

    if $expand {
        if $max_height == $dominant_sentinel {
            $max_height = $max_width * $meta.height / $meta.width | math floor
            $max_height += $max_height mod ($dominant_sentinel | math abs)
        }

        if $max_width == $dominant_sentinel {
            $max_width = $max_height * $meta.width / $meta.height | math floor
            $max_width += $max_width mod ($dominant_sentinel | math abs)
        }
    }

    {
        max_width: ($max_width | into int),
        max_height: ($max_height | into int)
    }
}

export def 'vid compare-frame' [
    a: path
    b: path
] {
    # -lavfi ssim for the comparison, scaling dance if they're different sizes
    let stderr = ffmpeg -i $a -i $b -lavfi "[1:v]scale=rw:rh[resized];[0:v][resized]ssim" -f null - | complete | get stderr

    try {
        $stderr | parse -r 'All:(\d\S+)' | get capture0.0 | into float
    } catch { |e|
        print -e $stderr
    }
}

export def 'vid compare-frames' [
    a: path
    ...others: path
    --frames: int = 999999999999
    --until: string = '10:00'
    --searchspace: int = 3 # Increases the amount of frames extracted from `a` fast
    --interval: int = 151
    --format = 'jpg' # Faster and has fewer problems with weird color space shifting
] {
    if ($others | is-empty) {
        error make {
            msg: 'Comparison paths is empty'
        }
    }

    let FRAME_SLICE = $searchspace * 2 + 1
    let RANGE_START = 0
    let RANGE_END = $FRAME_SLICE - 1
    let MIDDLE = $FRAME_SLICE / 2 | math floor | into int

    # const FRAME_SLICE = 5
    # const RANGE_START = 0 # 0-indexed
    # const RANGE_END = $FRAME_SLICE - 1 # inclusive frame 0-indexed range for between()
    # const MIDDLE = $FRAME_SLICE / 2 | math floor # Still 0-indexed

    rm -rf cmp

    mkdir cmp

    # If searchspace * 2 >= $interval, every frame will be extracted from the first path
    let filter = "select='between(mod(n,$interval),$min,$max)*lt(n,$frames)',setpts=N/FRAME_RATE/TB"
    let fa = $filter | str replace '$min' $"($RANGE_START)" | str replace '$max' $"($RANGE_END)" | str replace '$frames' $"($frames)" | str replace '$frames' $"($frames)"
 | str replace '$interval' $"($interval)"
    let fb = $filter | str replace '$min' $"($MIDDLE)" | str replace '$max' $"($MIDDLE)" | str replace '$frames' $"($frames)" | str replace '$frames' $"($frames)"
 | str replace '$interval' $"($interval)"
    # let to = $frames / 20 # assume 24 fps baseline; read this with ffprobe later
    let chars = seq char b z

    ffmpeg -ss 0 -to $until -i $a -vf $fa -fps_mode vfr $"cmp/a_%03d.($format)"
    # ffmpeg -ss 0 -to $until -i $b -vf $fb -fps_mode vfr $"cmp/b_%03d.($format)"
    for other in ($others | enumerate) {
        ffmpeg -ss 0 -to $until -i $other.item -vf $fb -fps_mode vfr $"cmp/($chars | get $other.index)_%03d.($format)"
    }

    # Compare every a frame in the ranges with the b frames, then apply their jitters to c..
    glob $'cmp/b_*.($format)' | each { |path|
        try {
            let index = $path | parse -r $"_\(\\d+).($format)" | get 0.capture0 | into int
            # File naming index that starts at 1 is very annoying for the intersection math
            let index = $index - 1

            let other_start = $index * $FRAME_SLICE
            let mid = $other_start + $MIDDLE

            let candidates = $other_start..<($other_start + $FRAME_SLICE) | par-each -k { |n|
                let name = $"cmp/a_($n + 1 | fill -a r -c 0 -w 3).($format)"
                if not ($name | path exists) {
                    print $"missing name: ($name)"

                    return { score: 0, name: $name }
                }

                let score = (vid compare-frame $name $path) - ($n - $mid | math abs) * 0.000001
                let score = $score | math round -p 6

                return { score: $score, name: $name }
            } | enumerate | sort-by item.score index -r

            let best = $candidates | first

            print -e $"Best score: ($best | get item.score | fill -a l -w 10) Worst score: ($candidates | last | get item.score | fill -a l -w 10) Jitter: ($best.index - $MIDDLE | math abs)"

            cp $best.item.name $"./cmp/($index).a.($format)"
            # cp $path $"./cmp/($index).($bn).($format)"
            for other in ($others | enumerate) {
                let chr = $chars | get $other.index
                cp ($path | str replace -r 'b(?=_\d+\.)' $chr) $"./cmp/($index).($chr).($format)"
            }
        } catch { |e| print -e $e }
    }

    rm ...(glob $'cmp/?_*.($format)')
}

export def 'vid _format-duration' [
    duration
    --notrim
    --nomillis
    --forcemillis
    --minsections: int = 1
] {
    # Handle negatives specially because the results get weird for negative durations
    let negative = $duration < 0sec
    let sign = if $negative { '-' } else { '' }
    let duration = $duration | math abs

    let hours = $duration / 1hr | math floor
    let duration = $duration - $hours * 1hr
    let minutes = $duration / 1min | math floor
    let duration = $duration - $minutes * 1min
    let seconds = $duration / 1sec | math floor
    let duration = $duration - $seconds * 1sec
    let millis = $duration / 1ms | math floor

    mut hms = ([$seconds, $minutes, $hours]
        | enumerate
        | reverse
        | skip while { |p| $p.item == 0 and $p.index >= $minsections }
        | get item
        | fill -w 2 -c 0 -a r
        | str join ':'
    )

    if not $notrim {
        # $hms = $hms | str trim -l -c '0' | default -e '0'
        $hms = $hms | str replace -r '^0+([\d]|$)' '$1' | str replace -r '^0+([\D])' '0$1' | default -e '0'
    }

    if (not $forcemillis and $millis == 0) or $nomillis {
        $"($sign)($hms)"
    } else {
        $"($sign)($hms).($millis | fill -w 3 -c 0 -a r)"
    }
}

# 8 0.970231 (+0.000000) (45sec 323ms)       (x1.000) (2.647x) (0.38x of runtime)
# 7 0.970826 (+0.000595) (59sec 560ms)       (x1.314) (2.014x) (0.5x of runtime)
# 6 0.973855 (+0.003029) (1min 21sec 844ms)  (x1.374) (1.466x) (0.68x of runtime)
# 5 0.973906 (+0.000051) (2min 6sec 324ms)   (x1.543) (0.949x) (1.05x of runtime)
# 4 0.975350 (+0.001444) (3min 47sec 333ms)  (x1.799) (0.527x) (1.89x of runtime)
# 3 0.975607 (+0.000256) (6min 58sec 119ms)  (x1.839) (0.286x) (3.48x of runtime)
# 2 0.976522 (+0.000914) (11min 22sec 811ms) (x1.633) (0.175x) (5.69x of runtime)
# 1 0.977456 (+0.000933) (26min 2sec 304ms)  (x2.288) (0.076x) (13.02x of runtime)

# Get latest ffmpeg build that includes svt 3.0 for a cool 15-35% speedup
#
# SSIM scores for presets (2min, 1080p, 30fps):
# | p | ssim     | time              | fps |
# | - | -------- | ----------------- | --- |
# | 1 | 0.975715 | 29m 3.9s (14.53x) | 2   |
# | 2 | 0.975    | 10m 53.5s (5.45x) | 5   |
# | 3 | 0.975352 | 6m 57s (3.48x)    | 8   |
# | 4 | 0.974002 | 3m 19.1s (1.66x)  | 18  |
# | 5 | 0.972721 | 1m 41.6s (0.85x)  | 35  |
# | 6 | 0.970879 | 1m 0.6s (0.51x)   | 59  |
# | 7 | 0.9694   | 49.6s (0.41x)     | 72  |
# | 8 | 0.962884 | 30s (0.25x)       | 119 |
# | 9 | 0.959705 | 22.8s (0.19x)     | 157 |
# | - | -------- | ----------------- | --- |
export def 'vid av1' [
    path: path
    --crf: int
    --preset(-p): int = 5
    --audio-bitrate(-a): oneof<filesize, int> = 96kb
    --video-bitrate: filesize = 1.5mb # Variable bitrate, maps to --maxrate
    --max: int = 1080 # The max dimensions of the smaller side (vertical for landscape, horizontal for portrait)
    # --verbosity: string = 'warning'
    --log-level: int = 1 # 1 for error, 2 for warning, 3 for info; this will apply to ffmpeg --verbosity and SVT_LOG
    --bin: string = "ffmpeg"

    --start: string = "0"
    --end: string = "10000000"

    --overlays
    --scd # Setting scd makes svt complain (but it always does)

    --video-filter: string # Video filter to apply; disables --max scaling. Scale manually if provided

    --10bit # Use 10-bit encoding for supposed efficiency and banding gains, at the expense of enc/dec performance

    --vsync # Explicitly use -fps_mode vfr

    --fps: int

    --rm # Remove the source file after encoding
    --overwrite # If target path exists, overwrite. Makes no sense with --count
    --count # If target path exists, add a counting number instead of aborting. Makes no sense with --overwrite

    # --log-level: int = 1 # Set to 3 to print encoder info. SvtApp has useless, irremediable warnings
    # --tune: int = 1 # 0: vq, 1: psnr, 2: ssim
    # --start: string = "0"
    # --end: string = "10000000"
    # --scd # Setting scd makes svt complain (but it always does)
    # --10bit
    # --rm
    # --count
] {
    if $path =~ '\.min\.' {
        print (ansiwrap yellow $"Skipping ($path | path basename): looks already compressed")
        return
    }

    if $count and $overwrite {
        print (ansiwrap yellow "Combination of --count and --overwrite makes no sense")
        return
    }

    let stat = ls -D $path | first
    let scale = vid get-default-scaling $path --max=$max

    let target = path interject $path min --ext mp4 --count=$count
    if ($target | path exists) and not ($overwrite or $count) {
        print (ansiwrap yellow $"Skipping ($path | path basename): already compressed")
        return
    }

    # Total bitrate is video + audio bitrate, `maxrate` is just for the crf video encoder
    let video_bitrate = $video_bitrate | into int
    let audio_bitrate = $audio_bitrate | into int

    mut log = $"Encoding (ansiwrap default_reverse ($path | path basename)): initial size (ansiwrap light_blue ($stat.size | into string))"

    try {
        let source_meta = vid get-meta $path
        let res = [$source_meta.width, $source_meta.height] | math min

        $log += $", duration (ansiwrap light_green (vid _format-duration $source_meta.duration)), "
        $log += (ansiwrap light_green $"($res)p") + ", "
        $log += (ansiwrap light_green $"($source_meta.fps | math round)fps")
    }

    print $log

    let video_filter = if $video_filter != null {
        $video_filter
    } else {
        $"scale=($scale.max_width):($scale.max_height)"
    }

    $env.SVT_LOG = $log_level

    # ffmpreg verbosity mapping
    let verbosity = match $log_level {
        1 => "error",
        2 => "warning",
        3 => "info"
    }

    (^$bin
        -v $verbosity
        -stats
        -stats_period 0.2
        -y
        ...(if $start != "0" or $end != "10000000" { [-ss $start -to $end] } else { [] })
        -i $path
        -c:v libsvtav1
        -preset $preset
        # Supports variable framerate with a synced fps_mode; kinda useless?
        # Incompatible with vfr mode because it obviously sets a constant framerate
        ...(if $fps != null { [-r $fps]} else { [] })

        ...(if $vsync { [-fps_mode vfr] } else { [] })

        # svt defaults to 35
        ...(if $crf != null { [-crf $crf] } else { [] })
        # 10bit is ~15% slower, but people seem to like it? it can also be a bit smaller
        ...(if $10bit { [-pix_fmt yuv420p10le] } else { [-pix_fmt yuv420p] })

        # tune:0 - VQ over PSNR. I can't tell the difference, but it seems faster
        # consider: enable-overlays=1, slows down a little, improves quality considerably, but with larger file sizes
        # consider: scm=1, slows down considerably, smaller file sizes
        # consider: scd=1, except svt av1 warns when using it

        -svtav1-params $'tune=0:enable-overlays=($overlays | into int):scd=($scd | into int)'
        -metadata $"comment='Encoded from video of size ($stat.size | into string)'"
        # Keyframe interval
        -g 289
        ...(if $video_bitrate > 0 { [
            -maxrate ($video_bitrate | $in / 1000 | $"($in)K")
            -bufsize ($video_bitrate | $in / 250 | $"($in)K")
        ] } else { [] })
        -vf $video_filter
        ...(if $audio_bitrate > 0 { [ -c:a libopus -b:a $audio_bitrate ] } else { [ '-an' ]})
        $target
    )

    let final_stat = ls -D $target | first

    let ret = print-encode-message $stat $final_stat $target

    if $rm and $ret.saved > 0kb {
        rm $path
    }
}

def print-encode-message [
    stat
    final_stat
    target: path
    start?
] {
    let saved = $stat.size - $final_stat.size
    let color = if $saved > 0kb { 'green' } else { 'red' }
    let percentage = $final_stat.size / $stat.size * 100 | math round -p 1

    let rpath = try {
        $target | path relative-to $env.PWD
    } catch {
        $target | path basename
    }

    mut message = $"Encoded (ansiwrap yellow_bold ($rpath)): final (ansiwrap light_blue ($final_stat.size | into string)), saved (ansiwrap $color $saved) \((ansiwrap light_blue $percentage)%\)"

    if $start != null {
        let elapsed = (date now) - $start
        let h = $elapsed / 1hr | math floor
        let m = $elapsed mod 1hr / 1min | math floor
        let s = $elapsed mod 1min / 1sec | math floor
        let ms = $elapsed mod 1sec / 1ms | math floor

        mut time = [$h $m $s] | skip while { |seg| $seg == 0 } | fill -a r -c 0 -w 2 | str join ":" | str trim -l -c 0 | default '0'

        if $ms > 0 {
            $time += $".($ms | fill -a r -c 0 -w 3)"
        }

        $message += $" in ($time)"
    }

    print $message

    return {
        saved: $saved
    }
}

export def yuv-pipe [
    path: string,
    scale: record<max_height: int, max_width: int> = { max_height: -1, max_width: -1 }
    --start: string = "0"
    --end: string = "10000000"
    --fps: int
    # --format = "yuv420p" # or yuv420p10le for 10bit
    --10bit
    --vsync # Force vfr fps_mode, which can stop 100fps videos from inconsistent framerates, but can break timestamps
    --nostats
    --noaccel
] {
    mut video_filter = if not $noaccel {
        if $10bit {
            $"scale_cuda=($scale.max_width):($scale.max_height):format=p010le:interp_algo=lanczos,hwdownload,format=p010le"
        } else {
            # Without format step, can fail on some videos with error "Invalid output format monow"
            $"scale_cuda=($scale.max_width):($scale.max_height):format=yuv420p:interp_algo=lanczos,hwdownload,format=yuv420p"
        }
    } else {
        $"scale=($scale.max_width):($scale.max_height)"
    }

    if $fps != null {
        $video_filter += $",fps=($fps)"
    }

    (ffmpeg
        ...(if not $noaccel { [
            -hwaccel cuda
            # Fixing cuda output format enables most of the speedup, need to hwdownload at the end
            -hwaccel_output_format cuda
            # Pin threads with hardware acceleration
            # Why? The goal is to reduce CPU time, but more importantly, nvdec can fail
            # with some videos (which - idk, but they fail consistently, even some 480p ones)
            # "Using more than 32 (35) decode surfaces might cause nvdec to fail."
            # Fixing a low amount of threads won't slow anything down and stops this
            -threads 4
        ] } else { })
        -v warning
        ...(if not $nostats { [-stats] } else { [] })
        # TODO: Do like with vcut an option to put the -to to a -t after the -i for some compat issues
        ...(if $start != "0" or $end != "10000000" { [-ss $start -to $end] } else { [] })
        -i $path
        # -fps_mode vfr # Fixes weirdly encoded videos with inconsistent fps but might mess with output
        ...(if $vsync { [ '-fps_mode', 'vfr' ] } else { [] })
        -map 0:v:0
        -vf $video_filter
        -pix_fmt (if $10bit { 'yuv420p10le' } else { 'yuv420p' })
        -f yuv4mpegpipe
        -strict -1
        -an
        -
    )
}

export def _yuv-split-test [
    filename: string
    callback: closure
    --mod: int = 2
    --endframe = 20
    --workers: int
] {
    let meta = vid get-meta $filename
    # yuv420 stores w*h luma, plus a quarter of that chroma for u/v
    let frame_byte_length = $meta.width * $meta.height * 3 / 2 | into int

    let status = {
        kind: 'started',
        bytez: 0x[]
    }

    let worker_count = if $workers == null {
        # Assume hyperthreading since -l doesn't provide EfficiencyClass for hyperthreading/p-e core cpus
        # (sys cpu | length) / 2 | into int
        sys cpu | length
    } else {
        $workers
    }

    let db_path = mktemp -t --suffix .db
    rm $db_path
    sqlite init $db_path [
        "PRAGMA synchronous=OFF",
        "CREATE TABLE IF NOT EXISTS broadcaster_table (worker INTEGER, frame BLOB)"
    ]

    let frame_tag = random int
    let availability_tag = random int
    let parent_id = job id

    let workers = 0..<$worker_count | each {
        job spawn {
            loop {
                let payload = job recv

                let ftag = $frame_tag

                match $payload.tag {
                    $tag if $tag == $availability_tag => {
                        let response = {
                            loopback: (job id)
                        }

                        $response | job send $payload.loopback --tag $availability_tag
                    },
                    $tag if $tag == $ftag => {
                        # let results = open $db_path | query db "SELECT frame FROM broadcaster_table WHERE worker = ?" -p [(job id)]
                        # let count = $results | length
                        # let frames = $results | get frame | bytes collect

                        # # print $"working at (job id) for ($payload.count) \(($count)) with ($frames | length) bytes"

                        # let result = $frames | do $callback

                        # $result | job send $parent_id --tag $frame_tag
                        let payload = {
                            worker: (job id),
                            getframes: { ||
                                open $db_path | query db "SELECT frame FROM broadcaster_table WHERE worker = ?" -p [(job id)] | get frame | bytes collect
                            },
                            index: $payload.index,
                            count: $payload.count
                        }


                        let result = $payload | do $callback

                        open $db_path | query db "DELETE FROM broadcaster_table WHERE worker = ?" -p [(job id)]

                        $result | job send $parent_id --tag $frame_tag
                    },
                    $tag => {}
                }
            }
        }
    }

    let broadcaster = job spawn {
        mut task_index = 0
        mut frames = {
            count: 0
        }

        loop {
            loop {
                # Clear mailbox
                try {
                    job recv --tag $availability_tag --timeout 0sec
                } catch {
                    break
                }
            }

            let frame = job recv --tag $frame_tag

            if $frame != 0x[] {
                let starty = date now
                open $db_path | query db "INSERT INTO broadcaster_table (worker, frame) VALUES (?, ?)" -p [null, $frame]
                # print (open $db_path | query db "SELECT COUNT(*) as cont FROM broadcaster_table" | get cont.0)

                $frames.count += 1

                # print ((date now) - $starty)
            }

            if $frames.count == $mod or ($frame == 0x[] and $frames.count != 0) {
                for worker in $workers {
                    let payload = {
                        count: $frames.count,
                        index: $task_index,
                        tag: $availability_tag,
                        loopback: (job id)
                    }

                    $payload | job send $worker --tag $availability_tag
                }

                let response = job recv --tag $availability_tag

                # print $"available worker ($response.loopback)"

                let starty = date now

                open $db_path | query db "UPDATE broadcaster_table SET worker = ? WHERE worker IS NULL" -p [$response.loopback]

                # print ((date now) - $starty)

                let payload = {
                    count: $frames.count,
                    tag: $frame_tag,
                    index: $task_index,
                    frames: $frames,
                    loopback: (job id)
                }

                $payload | job send $response.loopback --tag $frame_tag

                $task_index += 1
                $frames.count = 0
            }

            if $frame == 0x[] {
                1 | job send $parent_id --tag $availability_tag
            }
        }
    }

    def dispatch-1 [] {
        each { |c| $c | into binary } | reduce -f $status { |chunk, acc|
            let acc_bytes = bytes build $acc.bytez $chunk
            let FRAME = 0x[46 52 41 4d 45]
            let NEWLINE = 0x[0a]

            mut out_acc = $acc
            mut cursor = $acc_bytes

            if $acc.kind == 'started' {
                let nl = $cursor | bytes index-of $NEWLINE
                if $nl != null {
                    let sliced = $cursor | bytes at ($nl + 1)..

                    $out_acc = {
                        kind: 'frame',
                        bytez: $sliced
                    }

                    $cursor = $sliced
                } else {
                    return {
                        kind: 'started',
                        bytez: $cursor
                    }
                }
            } else {
                $out_acc = {
                    kind: 'frame',
                    bytez: $cursor
                }
            }

            loop {
                if not ($out_acc.bytez | bytes starts-with $FRAME) {
                    if ($out_acc.bytez | is-not-empty) {
                        # print "did not start with frame" $out_acc.bytez
                    }

                    break
                }

                let nl = $out_acc.bytez | bytes index-of $NEWLINE
                if $nl == -1 { break }

                let after_header = $nl + 1
                let remaining_len = ($out_acc.bytez | length) - $after_header

                if $remaining_len < $frame_byte_length {
                    # Not enough for a full frame yet
                    break
                }

                let before = $out_acc.bytez | bytes at $after_header..<($after_header + $frame_byte_length)
                let after = $out_acc.bytez | bytes at ($after_header + $frame_byte_length)..

                # print $"chunked ($before | length) at ($nl)"

                $before | job send $broadcaster --tag $frame_tag

                # Continue stripping the rest
                $out_acc = {
                    kind: 'frame',
                    bytez: $after
                }
            }

            return $out_acc
        } | ignore
    }

    def dispatch-2 [] {
        # Skip variable byte header, and group by the frame size plus a FRAME\n prefix
        # FRAME headers can contain metadata, so far, ffmpeg hasn't emitted any (and if it ever happens we're fucked)
        let results = skip (ffmpeg-command | bytes index-of 0x[0a] | $in + 1) | chunks ($frame_byte_length + 6) | each -k { |chunk|
            if ($chunk | length) != ($frame_byte_length + 6) {
                print "We're fucked (and we were probably fucked before we got to this point)"
            }

            let frame = $chunk | bytes at 6..

            $frame | job send $broadcaster --tag $frame_tag
        }

        print ($results | length)
    }

    def ffmpeg-command [] {
        ffmpeg -i $filename -loglevel quiet -vf $"trim=start_frame=0:end_frame=($endframe),setpts=PTS-STARTPTS" -f yuv4mpegpipe -pix_fmt yuv420p -
    }

    # print (ffmpeg-command | take 200)

    ffmpeg-command | dispatch-2

    print "FINISHED BATCHING UP FRAMES"

    # Empty buffer to mark EOF
    0x[] | job send $broadcaster --tag $frame_tag

    job recv --tag $availability_tag

    for worker in $workers {
        let payload = {
            count: 0,
            tag: $availability_tag,
            loopback: (job id)
        }

        $payload | job send $worker --tag $availability_tag
        job recv --tag $availability_tag
    }

    print "killing now"

    job kill $broadcaster
    for worker in $workers {
        job kill $worker
    }

    rm $db_path

    mut messages = []

    loop {
        try {
            $messages ++= [(job recv --tag $frame_tag --timeout 0sec)]
        } catch {
            break
        }
    }

    $messages
}

export def _batched-av1 [
    filename: string
    --mod: int = 15
    --endframe: int = 100
    --preset: int = 1
] {
    let parallelism = 1
    let meta = vid get-meta $filename
    let fps = $meta.fps | into int
    let w = $meta.width
    let h = $meta.height

    let results = _yuv-split-test $filename --mod $mod --endframe $endframe {
        let payload = $in
        let p = mktemp --suffix .ivf

        do $payload.getframes | (SvtAv1EncApp.exe
            -w $w
            -h $h
            --fps $fps
            --keyint $mod
            -n $mod
            --lp $parallelism
            --preset $preset
            -i stdin
            -b $p
        )

        {
            index: $payload.index,
            path: $p
        }
    }

    print $results

    $results | sort-by index | each { |result|
        $"file '($result.path)'\n" | save -a files.txt
    }

    ffmpeg -probesize 50M -analyzeduration 100M -f concat -safe 0 -i files.txt -c:v copy -y merged.mp4

    rm files.txt ...$results.path
}

export def 'vid concat' [
    paths
    output
    --framerate: int = 30
] {
    $paths | each { |p| $"file '($p)'" } | str join "\n" | save files.txt

    ffmpeg -r $framerate -f concat -safe 0 -i files.txt -y $output
}

# Defines how much it can overshoot the bitrate assigned - it shouldn't matter for 2-pass, but it does
# It makes it (a tiny bit) more aggressive in spiking the bitrate. It's still good w/o this
const OVERSHOOT_PCT_PERCENT = 100
const RC_VBR = 1

export def 'vid 2p av1' [
    path: path
    target_size: filesize = 10mib
    --preset(-p): int = 4
    --audio-bitrate(-a): oneof<filesize, int>
    --max: int # The max dimensions of the smaller side (vertical for landscape, horizontal for portrait)
    --log-level: int = 1 # Set to 3 to print encoder info. SvtApp has useless, irremediable warnings
    --tune: int = 1 # 0: vq, 1: psnr, 2: ssim
    --tbr: filesize # Override total bitrate - ignores target_size parameter. Bytes interpreted as bits (1mb = 1mbit)
    --start: string = "0"
    --end: string = "10000000"
    --scd # Setting scd makes svt complain (but it always does)
    --keyint: int # "Multiple of 32 plus one"; gop size; keyframe interval
    --rm
    --overwrite
    --count
    --ignoremin
    --10bit
    --bin = "SvtAv1EncApp"
] {
    def svt-app-2p [
        pass: int
        fps_ratio: list
        video_bitrate_kbits: int
        keyint: int
        target_stat: string
        target_ivf?: string
    ] {
        # We can do both passes in one invocation, but I don't know the implications on quality or mem/disk usage. It seems to be fine
        # Just set --passes to 2 (instead of --pass) and pass an output ivf path
        let results = (^$bin
            -i stdin
            --rc $RC_VBR
            --tune $tune
            --progress 0
            # --lookahead 42 # It warns us if we don't force it to 42
            --scd ($scd | into int)
            --overshoot-pct $OVERSHOOT_PCT_PERCENT
            --fps-num $fps_ratio.0
            --fps-denom $fps_ratio.1
            --tbr $video_bitrate_kbits
            --preset $preset
            --keyint $keyint
            --pass $pass
            --stats $target_stat
            ...(if $target_ivf != null { [ -b $target_ivf ] } else { [] })
        ) | complete

        if $results.exit_code != 0 {
            print -e "Svt invocation failure"
            print -e $results

            error make {
                msg: "err"
            }
        }
    }

    if $path =~ '\.min\.' and not $ignoremin {
        print (ansiwrap yellow $"Skipping ($path | path basename): looks already compressed")
        return
    }

    $env.SVT_LOG = $log_level

    let target = path interject $path min --ext mp4 --count=$count
    let target_ivf = path interject $target --ext ivf
    let target_stat = path interject $target --ext stat
    if ($target | path exists) and not ($overwrite or $count) {
        print (ansiwrap yellow $"Skipping ($path | path basename): already compressed")
        return
    }

    # Touch target and use it for subsequent files to avoid collisions
    touch $target

    let meta = vid get-meta $path
    let start_time = parse-time $start
    let end_time = [(parse-time $end), ($meta.duration / 1sec)] | math min
    let duration_s = $end_time - $start_time

    # SVT vbr is really good at matching it as long as it's not unreasonable (bitrate for scale, or fast preset)
    # Faster presets (9+) can even be kinda bad and undershoot it by as much as 20%, giving us a 1.2 threshold!
    # This is not implemented. The most I've seen it overshoot under normal use is 1mb/50mb on some rare videos
    # (50 * 0.96 = 48, result is 49mb; tight.)
    let fallibility_threshold = if $tbr != null {
        # Using tbr we don't mess with the video codec bitrate at all
        1
    } else if $preset <= 4 {
        # Slow preset, assume decent precision
        0.98
    } else {
        # Mid to faster preset, assume not so decent precision
        0.96
    }

    let target_bitrate_bits = $tbr | default ($target_size / $duration_s * 8) | into int
    let audio_bitrate_bits = $audio_bitrate | default (match $target_bitrate_bits {
        0..<120000 => 0, # Sub 120kbps for total bit stream - we're so cooked, strip audio
        120000..<300000 => 32000,
        300000..<900000 => 64000,
        _ => 96000
    }) | into int
    let video_bitrate_kbits = ($target_bitrate_bits - $audio_bitrate_bits) / 1000 * $fallibility_threshold | math floor
    let max_res = $max | default (match $video_bitrate_kbits {
        # "real" bitrate floors: (all depend on preset and complexity of the video)
        # 200-140kbps for 1080p video
        # 120-90kbps for 720p video
        # 75-55kbit for 480p video
        # (... but this is just a heuristic, and I choose the values)
        0..120 => 480,
        120..250 => 720,
        _ => 1080
    })
    let scale = vid get-default-scaling $path --max $max_res

    # GOP/keyframes; -2 for default of ~5 secs
    # "it is recommended to have keyint be a multiple of 32 + 1 (225 or 257 for instance) to respect the mini-gop structure."
    # I can't speak to its impact on quality, but it seems to measurably improve encode time
    let keyint = $keyint | default 289

    print $"($scale.max_width):($scale.max_height); ($target_bitrate_bits / 1000)kbit: ($audio_bitrate_bits / 1000) audio, ($video_bitrate_kbits) video; ($keyint) keyint"

    # SvtAv1EncApp calls take -w/-h for input stream, but seems to ignore it. We have to scale when piping it yuv stream
    # https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/svt-av1_encoder_user_guide.md

    # Pipe for stats.
    yuv-pipe --10bit=$10bit $path $scale --start $start --end $end | svt-app-2p 1 $meta.fps_ratio $video_bitrate_kbits $keyint $target_stat

    # Second pass (it can't have 3 passes, thankfully, despite what the user guide says)
    yuv-pipe --10bit=$10bit $path $scale --start $start --end $end | svt-app-2p 2 $meta.fps_ratio $video_bitrate_kbits $keyint $target_stat $target_ivf

    print $"moving to container..."
    let include_audio = $audio_bitrate_bits > 0

    # Move ivf to new container
    (ffmpeg
        -v warning
        -i $target_ivf
        ...(if $start != "0" or $end != "10000000" { [-ss $start -to $end] } else { [] })
        ...(if $include_audio { [-i $path] } else { [] })
        -map 0:v
        -c:v copy
        # We could've done the audio transcode in parallel before, but it's fast enough... maybe as fast as I/O
        ...(if $include_audio { [ -map 1:a:0? -c:a libopus -b:a $audio_bitrate_bits -af 'aformat=channel_layouts=stereo|mono' ] } else { [ -an ] })
        -y
        $target
    )

    let final_size = ls -D $target | first | get size
    print $"Final size: ($final_size | into string)"

    rm $target_ivf $target_stat
    if $rm {
        rm $path
    }
}

export def 'vid av1 crf' [
    path: path
    --crf: int = 35
    --video-bitrate = 1.5mb # Variable bitrate, maps to --mbr
    --preset(-p): int = 6
    --audio-bitrate(-a): oneof<filesize, int> = 96kb
    --max: int # The max dimensions of the smaller side (vertical for landscape, horizontal for portrait)
    --log-level: int = 1 # Set to 3 to print encoder info. SvtApp has useless, irremediable warnings
    --tune: int = 1 # 0: vq, 1: psnr, 2: ssim
    --start: string = "0"
    --end: string = "10000000"
    --scd # Setting scd makes svt complain (but it always does)
    --10bit
    --vsync
    --rm
    --overwrite
    --count
] {
    if $path =~ '\.min\.' {
        print (ansiwrap yellow $"Skipping ($path | path basename): looks already compressed")
        return
    }

    let meta = vid get-meta $path

    let printer = job spawn {
        mut buffer = ""
        mut maxlen = 0
        mut done_printing = false
        mut last_frames = 0
        mut last_bitrate = 0
        # mut last_time = date now
        mut ema_bitrate = 0
        # mut ema_fps = 0

        let start_time = date now
        let regex = '(?x)
            Encoding:
            \s*(?<encoded>\d+)\s*
            /
            \s*(?<total>-?\d+(?:\.\d+)?)
            \s*Frames\s*@\s*
            (?<fps>-?\d+(?:\.\d+)?)\s*
            (?<fpunit>fp[sm])
            \s*\|\s*
            (?<bitratekbps>-?\d+(?:\.\d+)?)
            \s*kbps\s*\|\s*Time:\s*
            (?<time>\d+:\d+:\d+)
            \s*
            (?<remaining>\[-{0,2}\d+:-?\d+:-?\d+\])?
            \s*\|\s*Size:\s*
            (?<size>-?\d+(?:\.\d+)?)
            \s*(?<sizeunit>[KMG]B)
            \s*
            (?<remainingsize>\[[^\[]+\])
        '

        loop {
            let chunk = job recv

            $buffer += if (type-is $chunk string) { $chunk } else { $chunk | decode utf-8 }

            loop {
                let first = $buffer | str replace -r '(\r\n|\r|\n)[\s\S]*' '$1'
                if $first == $buffer {
                    break
                }

                $buffer = $buffer | str substring ($first | str length | $in)..

                let summaried = $first =~ "SUMMARY"

                if ($summaried) {
                    print ''
                    $done_printing = true
                }

                if $done_printing {
                    break
                }

                # if ($first !~ 'Encoding') {
                #     break
                # }

                let parsed = $first | parse -r $regex | get 0?

                if $parsed == null {
                    print -en $first
                } else {
                    # print ''
                    # print $parsed

                    let encoded = $parsed.encoded | into int
                    let elapsed = (date now) - $start_time
                    let time_per_frame = $elapsed / $encoded
                    let time_to_finish = $time_per_frame * $meta.frames - $elapsed
                    let at = $encoded / $meta.fps * 1sec

                    let elapsed_f = vid _format-duration $elapsed --minsections 2 --nomillis
                    let left_f = vid _format-duration $time_to_finish --minsections 2 --nomillis
                    let at_f = vid _format-duration $at --minsections 2 --nomillis

                    # let new_time = date now
                    let new_frames = $parsed.encoded | into int
                    let new_bitrate = $parsed.bitratekbps | into float
                    let frames_this_update = $new_frames - $last_frames
                    # let bitrate_update = $new_frames * $new_bitrate - $last_frames * $last_bitrate
                    let chunk_bitrate = ($new_frames * $new_bitrate - $last_frames * $last_bitrate) / $frames_this_update
                    # let new_fps = ($new_frames - $last_frames) / (($new_time - $last_time) / 1sec)

                    # Apply EMA smoothing over ~20 frames-ish (update events)
                    let alpha = 1 / 20
                    $ema_bitrate = $ema_bitrate + $alpha * ($chunk_bitrate - $ema_bitrate)

                    $last_frames = $new_frames
                    $last_bitrate = $new_bitrate
                    # $last_time = $new_time

                    # Parsed size is always in metric megabytes
                    let size_mib = ($parsed.size | into float) * 1mb / 1mib | math round -p 1

                    mut line = ""
                    $line += $"Encoded ($parsed.encoded)/($meta.frames) frames @ ($parsed.fps)($parsed.fpunit)"
                    $line += $" | at ($at_f) / took ($elapsed_f) [($left_f) left]"
                    $line += $" | ($size_mib)mb \(($new_bitrate | into string -d 1)kbps\) | ($ema_bitrate | into string -d 1)kbps"
                    $line += $" [($frames_this_update)]"

                    $maxlen = [$maxlen ($line | str length)] | math max

                    print -en $"\r(str repeat ' ' $maxlen)\r($line)"
                }

                # let first = ($first
                #     | str replace -r '\s*-1\s' $"($meta.frames) "
                #     | str replace -r '\s*\[-{0,2}\d+:-?\d+:-?\d+\]' ''
                #     | str replace "\r" $"(str repeat ' ' 15)\r"
                # )

                # print -en $"printer: ($first)"
            }
        }
    }

    let backpressure = job spawn {
        mut buffer = ""

        mut last_time = (date now) - 1sec

        loop {
            mut chunk = job recv

            $buffer += if (type-is $chunk string) { $chunk } else { $chunk | decode utf-8 }

            loop {
                let first = $buffer | str replace -r '(\r\n|\r|\n)[\s\S]*' '$1'
                if $first == $buffer {
                    break
                }

                $buffer = $buffer | str substring ($first | str length | $in)..
                let now = date now

                if ($now - $last_time) > 20ms {
                    $first | job send $printer
                    $last_time = $now
                }
            }
        }
    }

    def svt-app-1p [
        fps_ratio: list
        video_bitrate_kbits: int
        keyint: int
        target_ivf?: string
    ] {
        (SvtAv1EncApp
            -i stdin
            --passes 1
            --tune $tune
            # --progress 0
            --progress 2
            --crf $crf
            # --lookahead 42 # It warns us if we don't force it to 42
            --scd ($scd | into int)
            --overshoot-pct $OVERSHOOT_PCT_PERCENT
            --fps-num $fps_ratio.0
            --fps-denom $fps_ratio.1
            --rc $RC_VBR
            # note: capped crf uses mbr, not tbr
            # set video-bitrate to 0 for uncapped crf, as some videos break the encoder on capped crf
            ...(if $video_bitrate_kbits > 0 { [--mbr $video_bitrate_kbits ]} else { [] })
            --preset $preset
            --keyint $keyint
            ...(if $target_ivf != null { [ -b $target_ivf ] } else { [] })
        ) e>| each { |chunk|
            $chunk | job send $backpressure
        }
    }

    $env.SVT_LOG = $log_level

    let target = path interject $path min --ext mp4 --count=$count
    let target_ivf = path interject $target --ext ivf
    if ($target | path exists) and not ($overwrite or $count) {
        print (ansiwrap yellow $"Skipping ($path | path basename): already compressed")
        return
    }

    # Touch target and use it for subsequent files to avoid collisions
    # touch $target

    let stat = ls -D $path | first
    let start_time = parse-time $start
    let end_time = [(parse-time $end), ($meta.duration / 1sec)] | math min
    let duration_s = $end_time - $start_time

    let target_bitrate_bits = $video_bitrate | into int
    let audio_bitrate_bits = $audio_bitrate | default 96000 | into int
    let video_bitrate_kbits = $target_bitrate_bits / 1000 | math floor
    let max_res = $max | default 1080
    let scale = vid get-default-scaling $path --max $max_res

    # GOP/keyframes; -2 for default of ~5 secs
    # "it is recommended to have keyint be a multiple of 32 + 1 (225 or 257 for instance) to respect the mini-gop structure."
    # I can't speak to its impact on quality, but it seems to measurably improve encode time
    let keyint = 289

    # print $"($scale.max_width):($scale.max_height); ($target_bitrate_bits / 1000)kbit: ($audio_bitrate_bits / 1000) audio, ($video_bitrate_kbits) video; ($keyint) keyint"

    mut log = $"Encoding (ansiwrap default_reverse ($path | path basename)): from (ansiwrap light_blue ($stat.size | into string))"

    try {
        let source_meta = vid get-meta $path
        let res = [$source_meta.width, $source_meta.height] | math min

        $log += $" (ansiwrap light_cyan (vid _format-duration $source_meta.duration)), "
        # $log += (ansiwrap light_green $"($res)p") + ", "
        $log += $"(ansiwrap light_green $"($res)p") "
        $log += (ansiwrap light_green $"($source_meta.fps | math round)fps")
    }

    print $log

    try {
        yuv-pipe $path $scale --vsync=$vsync --10bit=$10bit --start $start --end $end --nostats | svt-app-1p $meta.fps_ratio $video_bitrate_kbits $keyint $target_ivf
    } catch { |e|
        print -e "Failed or cancelled encode" $e

        rm $target

        return
    }

    # Move ivf to new container
    (ffmpeg
        -v warning
        -i $target_ivf
        ...(if $start != "0" or $end != "10000000" { [-ss $start -to $end] } else { [] })
        -i $path
        -map 0:v
        -c:v copy
        # We could've done the audio transcode in parallel before, but it's fast enough... maybe as fast as I/O
        ...(if $audio_bitrate_bits > 0 { [ -map 1:a? -c:a libopus -b:a $audio_bitrate_bits -af 'aformat=channel_layouts=stereo|mono' ] } else { [ -an ] })
        # Copy subtitles if they exist, and use the mov_text codec since that's what mp4 supports
        -map 1:s?
        -c:s mov_text
        -metadata $"comment='Encoded from video of size ($stat.size | into string)'"
        -y
        $target
    )

    let final_stat = ls -D $target | first

    print ""
    let ret = print-encode-message $stat $final_stat $target

    print ""

    rm $target_ivf
    if $rm {
        rm $path
    }

    job kill $printer
}

export def 'vid extract-frames' [
    ...paths
    --every: int = 1
    --to = "frames"
    --from: string
    --until: string
    --crop: string
    --format = "jpg"
] {
    rm -rf $to
    mkdir $to

    mut vf = "select='not(mod(n, " + $"($every)" + "))'"
    if $crop != null {
        $vf += $",crop=($crop)"
    }
    let chars = seq char a z
    mut $time_args = []
    if $from != null {
        $time_args ++= [-ss $from]
    }

    if $until != null {
        $time_args ++= [-to $until]
    }

    let time_args = $time_args
    let vf = $vf

    $paths | enumerate | par-each { |pair|
        let index = $pair.index
        let path = $pair.item
        let template = $"($to)/frame%05d($chars | get $index).($format)"

        (ffmpeg
            -hwaccel cuda
            ...$time_args
            # -colorspace bt709
            # -color_trc bt709
            # -color_primaries bt709
            -i $path
            -vf $vf
            -fps_mode vfr
            $template
        )
    }

    null
}

const RC_CRF = 1

export def get-crf-bitrate [
    path: path
    --crf: int = 35
    --preset(-p): int = 6
    --max: int = 1080
    --tune: int = 1
    --mbr: filesize = 1.5mb
    --keyint: int = 289
    --start: string = "0"
    --end: string = "300"
] {
    let target_ivf = vid get-default-filename $path --ext ivf
    let scale = vid get-default-scaling $path --max $max
    let meta = vid get-meta $path
    let stat = ls -D $path | first

    mut log = $"Gauging crf for (ansiwrap default_reverse ($path | path basename)): initial size (ansiwrap light_blue ($stat.size | into string))"

    try {
        let source_meta = vid get-meta $path
        let res = [$source_meta.width, $source_meta.height] | math min

        $log += $", duration (ansiwrap light_green (vid _format-duration $source_meta.duration)), "
        $log += (ansiwrap light_green $"($res)p") + ", "
        $log += (ansiwrap light_green $"($source_meta.fps | math round)fps")
    }

    print $log

    yuv-pipe $path $scale --start 0 --end $end | (SvtAv1EncApp
        -i stdin
        --rc $RC_CRF
        # --progress 0
        --crf $crf
        --mbr ($mbr / 1000 | into int)
        --preset $preset
        --keyint $keyint
        -b $target_ivf
    ) o+e>| ignore

    let duration_secs = [($end | into int) ($meta.duration / 1sec)] | math min
    let target_size = ls -D $target_ivf | get 0.size

    rm $target_ivf

    print $"($target_size) for ($duration_secs)secs"

    $target_size / $duration_secs * 8
}

export def 'vid 2p av1 crf' [
    path: path
    --crf: int = 35
    --preset(-p): int = 6
    --audio-bitrate(-a): oneof<filesize, int> = 96kb
    --max: int = 1080 # The max dimensions of the smaller side (vertical for landscape, horizontal for portrait)
    --log-level: int = 1 # Set to 3 to print encoder info. SvtApp has useless, irremediable warnings
    --tune: int = 1 # 0: vq, 1: psnr, 2: ssim
    --tbr: filesize = 1.5mb # Maximum total bitrate. Bytes interpreted as bits (1mb = 1mbit)
    --tbr2p: filesize = 3mb # Maximum bitrate used for the fallback 2-pass mode
    --rm
] {
    if $path =~ '\.min\.' {
        print (ansiwrap yellow $"Skipping ($path | path basename): looks already compressed")
        return
    }

    $env.SVT_LOG = $log_level

    let target = vid get-default-filename $path --ext mp4
    if ($target | path exists) {
        print (ansiwrap yellow $"Skipping ($path | path basename): already compressed")
        return
    }

    let predicted_crf = get-crf-bitrate $path
    # CRF overshoot tends to cap out at 15%, and we add a 10% floor for 25%
    # Why? Our prediction is based on the first 5min of video. This segment can be lower entropy (intros, low action)
    # and take up a larger portion of the "total" size. Fallback 2-pass encodes at a higher target, so we compensate
    let threshold = $tbr * 0.9

    print -e $"CRF prediction encoded at ($predicted_crf), (
        $predicted_crf - $threshold | into string | str replace - ''
    ) (
        if $predicted_crf > $threshold { "over" } else { "under" }
    ) threshold"

    if $predicted_crf > $threshold {
        # Encode it in two passes. And since the video is more complex to meet crf, we bump the $tbr2p value
        # It's quite a bit higher, but 2-pass has the opposite "problem", in that it often undershoots its target
        # (despite using it more efficiently). So 1.8mbit might be 1.4mbit, and 2.3mbit might be 2mbit
        vid 2p av1 $path --preset $preset --tbr $tbr2p --audio-bitrate $audio_bitrate --max $max --tune $tune --rm=$rm
    } else {
        vid av1 $path --preset $preset --audio-bitrate $audio_bitrate --max $max --rm=$rm
    }
}

export def 'vid plot' [
    ...paths: path
] {
    parallel ...($paths | each { |path| { plotbitrate $path e>| each { |chunk| print -en $chunk } } })
}

export def 'vid av1-folder' [
    --max: int = 1080
    --video-bitrate: oneof<closure, filesize> = 1.5mb
    --preset: int
    --crf: int = 35
] {
    let preset = $preset | default-param "vid av1 crf" preset

    glob '**/*.{mp4,webm,mkv,avi,m4v,mpg,wmv,mov,flv,m2ts}' | each { |p|
        let video_bitrate = if (type-is $video_bitrate closure) {
            do $video_bitrate (vid get-meta $p)
        } else {
            $video_bitrate
        }

        vid av1 $p --rm --max $max --video-bitrate $video_bitrate --preset $preset --crf $crf
    } | ignore
}

export def 'vid av1-folder-2p-crf' [] {
    glob '**/*.{mp4,webm,mkv,avi,m4v,mpg,wmv,mov,flv,m2ts}' | each { |p| vid 2p av1 crf $p --rm } | ignore
}

export def 'vid get-alpha-streams' [
    path: path
] {
    let streams = try {
        ffprobe -v error -select_streams v -show_entries stream -of json -i $path | from json | get streams
    } catch {
        return null
    }

    let color_streams = $streams | where $it has pix_fmt and pix_fmt !~ gray
    let gray_streams = $streams | where $it has pix_fmt and pix_fmt =~ gray

    if ($color_streams | length) != ($gray_streams | length) {
        # Can't match gray with color video streams
        return null
    }

    if ($color_streams | length) == 1 {
        return [$color_streams.0.index, $gray_streams.0.index]
    }

    # More than 1, but equal count gray/color streams. Try to filter preview/fallback/cover/thumbnail
    # from results, otherwise bail out
    let color_streams = $color_streams | where { |r| ($r.nb_frames | into int) > 1 }
    let gray_streams = $gray_streams | where { |r| ($r.nb_frames | into int) > 1 }

    if ($color_streams | length) == 1 and ($color_streams | length) == ($gray_streams | length) {
        return [$color_streams.0.index, $gray_streams.0.index]
    }

    return null
}

export def 'vid has-transparency' [
    path: path
] {
    let NALPHA_FORMATS = [
        # alpha formats: rgba, bgra, rgba64be, yuva420p, argb, ya8, pal8 (likely)
        'rgb24',
        rgb48be,
        'gbrp',
        'yuv420p',
        'yuv420p10le',
        'yuvj444p',
        'yuvj440p',
        'yuvj422p',
        'yuvj420p',
        'gray',
        'gray16be'
    ]

    mut color_stream = -1
    mut gray_stream = -1

    try {
        # Weed out non-alpha formats inexpensively
        let probe = ffprobe -v error -select_streams v -show_entries stream -of json -i $path | complete

        if ($probe.stdout | from json | get -o streams) == null {
            print $probe
        }

        let streams = $probe.stdout | from json | get streams

        # let formats = $probe.stdout | parse -r 'pix_fmt=(?<fmt>\w+)'

        if ($streams | length) == 1 {
            let format = $streams.0

            if $format.pix_fmt? in $NALPHA_FORMATS {
                return false
            }
        } else {
            let gray_streams = $streams | where $it has pix_fmt and pix_fmt =~ gray
            let color_streams = $streams | where $it has pix_fmt and pix_fmt !~ gray

            if ($gray_streams | length) == ($color_streams | length) {
                if ($gray_streams | length) > 1 {
                    let gray_streams = $gray_streams | where { |r| ($r.nb_frames | into int) > 1 }
                    let color_streams = $color_streams | where { |r| ($r.nb_frames | into int) > 1 }

                    if ($gray_streams | length) == 1 {
                        print "Selected animated streams from multi-stream-pair transparent format"
                        $gray_stream = $gray_streams.0.index
                        $color_stream = $color_streams.0.index
                    }
                } else {
                    print "Selected streams from multi-stream transparent format"
                    $gray_stream = $gray_streams.0.index
                    $color_stream = $color_streams.0.index
                }
            }
        }
    } catch { |e|
        print -e $"error for ($path):\n($e)"
    }

    let filter_args = if $gray_stream != -1 and $color_stream != -1 {
        [-filter_complex $"[0:v:($color_stream)][0:v:($gray_stream)]alphamerge,alphaextract,signalstats,metadata=print"]
    } else {
        [-vf 'alphaextract,signalstats,metadata=print']
    }

    # Fully scanning after ffprobe can't confirm non-alpha fmt in case it's encoded with rgba but has no transparent pixels
    let completion = ffmpeg -i $path ...$filter_args -f null - | complete

    # print $filter_args $completion

    let has_transparency = ($completion.stderr
        # YMIN is what we want over YLOW, since any transparency at all will show up
        | parse -r 'lavfi.signalstats.YMIN=(?<yuv>\d+)'
        # TODO: Yuv is based on color space range, so for non-8bit it can be higher
        # So from 1024 up to 65k for some formats
        | any { |match| ($match.yuv | into float) < 255 }
    )

    return $has_transparency
}

export def 'vid extract-alpha-mask' [
    path: path
    --binary
    --reversed
] {
    mut filter = if $binary {
        if $reversed {
            # Fully white pixels if they're not opaque (alpha != 255)
            "alphaextract,geq=lum='if(eq(lum(X,Y),255),255,0)',negate,format=gray"
        } else {
            # Fully white pixels if they're translucent (alpha < 255)
            "alphaextract,geq=lum='if(lum(X,Y),0,255)',negate,format=gray"
        }
    } else {
        "alphaextract,format=gray"
    }

    let streams = vid get-alpha-streams $path
    if $streams != null {
        $filter = $"[0:v:($streams.0)][0:v:($streams.1)]alphamerge,($filter)"
    }

    let target = path interject $path alpha --ext png --count

    ffmpeg -i $path -filter_complex $filter $target
}

export def 'vid avif' [
    path: path

    --crf: int = 22
    --preset(-p): int = 0 # maps to cpu-used, 0..6
    --max: int # The max dimensions of the smaller side (vertical for landscape, horizontal for portrait)
    --tune: int = 1 # 0: vq, 1: psnr, 2: ssim
    --fmt = "yuv420p" # Some decoders (like C# AvifNative for paint.net or ImageGlass) fail for BIG images in 10bit
    --denoiser: int = 0 # 4 is good and reduces file size but sometimes just fails silently
    --svt # svt will fail for images under 4px, but also for images under 25px (bug?) might also not handle uneven res
    --parallelism: int

    --progress
    --rm
    --overwrite
    --count
] {
    let streams = vid get-streams $path
    let meta = vid get-meta $path '-count_frames'

    let target_path = path interject $path --ext avif --count=$count
    if ($target_path | path exists) and not ($overwrite or $count) {
        print (ansiwrap yellow $"Skipping ($path | path expand | path relative-to ($env.PWD | path expand)): already compressed")
        return
    }

    let stat = ls -D $path | first
    let start_time = date now

    mut log = $"Encoding (ansiwrap default_reverse ($path | path basename)): initial size (ansiwrap light_blue ($stat.size | into string))"

    print $log

    $env.SVT_LOG = 2

    mut svt = $svt

    let has_transparency = vid has-transparency $path

    mut svt_params = ['tune=0']
    mut aom_params = []

    let max_frame_count = try {
        $streams | get props.nb_frames? | each { try { into int } } | math max
    } catch {
        1 # Idk whether to default to 2 or 1, erring on still or caution
    }

    if $meta.frames == 1 and $max_frame_count == 1 and ($path | path parse | get extension) != 'gif' {
        $svt_params ++= ['avif=1']
    }

    if $denoiser != null and $denoiser > 1 {
        $svt_params ++= [$'film-grain=($denoiser):film-grain-denoise=1']
        $aom_params ++= [$'denoise-noise-level=($denoiser)']
    }

    if $parallelism != null {
        $svt_params ++= [$'lp=($parallelism)']
    }

    loop {
        let wassvt = $svt
        $svt = false

        let alpha_streams = vid get-alpha-streams $path
        # if $alpha_streams != null {
        #     let $filter = $"[0:v:($alpha_streams.0)][0:v:($alpha_streams.1)]alphamerge"
        # }

        # Tpad pads the end with a single short frame for gifs with a lasting last frame
        # In practice this just inserts one frame at most and fixes timing issues
        let tpad_filter = if ($path | path parse | get extension) == 'gif' {
            "tpad=stop_mode=clone:stop_duration=0.01,"
        } else {
            ""
        }

        let transparency_filters = if $has_transparency {
            let filter = if $alpha_streams != null {
                $"[0:v:($alpha_streams.0)][0:v:($alpha_streams.1)]alphamerge,format=pix_fmts=yuva444p[main]; [main]($tpad_filter)split[main][alpha]; [main]format=pix_fmts=yuv420p[main]; [alpha]alphaextract[alpha]"
            } else {
                $"[0:v]format=pix_fmts=yuva444p[main]; [main]($tpad_filter)split[main][alpha]; [main]format=pix_fmts=yuv420p[main]; [alpha]alphaextract[alpha]"
            }

            [
                -pix_fmt:0 yuv420p -pix_fmt:1 gray8
                -filter_complex $filter
                -map "[main]:v"
                -map "[alpha]:v"
                -c:v:0 (if $wassvt { 'libsvtav1' } else { 'libaom-av1' })
                -c:v:1 'libaom-av1'
            ]
        } else {
            [
                -pix_fmt $fmt
                -vf $"($tpad_filter)format=($fmt)"
                # -frames:v (2 + 2)
                -c:v (if $wassvt { 'libsvtav1' } else { 'libaom-av1' })
            ]
        }

        # print $transparency_filters $wassvt

        try {
            (ffmpeg
                -loglevel warning
                ...(if $progress { [ '-stats' ] } else { [] })
                -i $path
                # Avoids duplicating thousands of frames on gif inputs
                -fps_mode vfr
                ...$transparency_filters
                # -still-picture 1
                -crf $crf
                (if $wassvt { '-preset' } else { '-cpu-used' }) $preset
                ...(if $wassvt {
                    [-svtav1-params ($svt_params | str join :) ]
                } else {
                    [-aom-params ($aom_params | str join :)]
                })
                # ...(if $denoiser != null { [-aom-params $'denoise-noise-level=($denoiser)'] } else { [] })
                -y
                $target_path
            )

            break
        } catch {
            print $"Error while encoding ($path)"
            if not $wassvt {
                break
            }
        }
    }

    let final_stat = ls -D $target_path | first

    if $final_stat.size == 0b {
        print -e $"Failed while encoding ($path | path basename)"
        return
    }

    let ret = print-encode-message $stat $final_stat $target_path $start_time

    if $rm and $ret.saved > 0kb {
        rm $path
    }

    return $target_path
}

export def 'vid avif-folder' [
    --preset: int = 0
    --threads: int = 8
    --crf: int = 25
    --norm
] {
    let rm = not $norm
    glob '**/*.{png,jpg,jpeg,jfif,gif,webp,heif}' | par-each -t $threads { |p| vid avif $p --preset $preset --crf $crf --rm=$rm --svt } | ignore
}

export def 'vid folder-duration' [] {
    glob '**/*.{mp4,webm,mkv,avi,m4v,mpg,wmv,mov,flv,m2ts}'
        | par-each { |v|
            try {
                vid get-meta $v | merge { path: $v, count: 1 } | insert pixels_capped { |r| [($r.width * $r.height), (1080 * 1980)] | math min }
            } catch {
                print $"Failed probing file: ($v)"
                null
            }
        }
        | select duration frames pixels_capped count
        | math sum
        | insert duration_1080p { |r| $r.duration * ($r.pixels_capped / (1080 * 1980) / $r.count) }
        | insert duration_30fps { |r| $r.frames / 30 | into duration -u sec }
        | insert duration_30fps1080p { |r| $r.duration_30fps * ($r.pixels_capped / (1080 * 1980) / $r.count) }
        | reject frames pixels_capped
}

export def 'vid h265-encode' [
    path: path,
    --bitrate: filesize = 1.5mb
    --preset: string = "medium"
    --crf: int = 24
] {
    let scale = vid get-default-scaling $path
    let target = vid get-default-filename $path
    if ($target | path exists) {
        return
    }

    (ffmpeg
        -v quiet
        -stats
        -i $path
        -c:v libx265
        -preset $preset
        -crf $crf
        -maxrate ($bitrate | into int)
        -bufsize ($bitrate * 2 | into int)
        -c:a aac
        -b:a 128k
        -vf $"scale=($scale.max_width):($scale.max_height)"
        $target
    )
}

export def 'vid vp9-encode' [
    path: path,
    --bitrate: filesize = 1.5mb
    --preset: string = "medium"
    --crf: int = 30
] {
    let scale = vid get-default-scaling $path
    let target = vid get-default-filename $path
    if ($target | path exists) {
        return
    }

    (ffmpeg
        -v quiet
        -stats
        -i $path
        -c:v libvpx-vp9
        -b:v ($bitrate | into int)
        -crf $crf
        -maxrate ($bitrate | into int)
        -bufsize ($bitrate * 2 | into int)
        -speed 2
        -c:a libopus
        -b:a 128k
        -vf $"scale=($scale.max_width):($scale.max_height)"
        $target
    )
}

export def 'vid h265-2pass' [
    path: path,
    filesize?: filesize,
    --preset: string = "medium" # Medium is good enough and 2x faster than slow
    --audio-codec: string = "opus" # opus or aac
    --audio-bitrate: filesize
    --no-audio
] {
    # 90-95% of the total bitrate seems to be enough to not jump over filesize
    # Rather tight and might need adjusting, however
    let exact = $filesize != null
    let filesize = if $filesize == null { 10mib } else { $filesize }
    let FALLIBILITY_THRESHOLD = if $exact { 1 } else { 0.95 }

    let scale = vid get-default-scaling $path
    let target = vid get-default-filename $path
    let meta = vid get-meta $path
    let duration = $meta.duration | into int | $in / 1000000000 # micros in 1sec
    let audio_bitrate = if $no_audio {
        0
    } else if $audio_bitrate != null {
        $audio_bitrate | into int
    } else if $audio_codec == 'opus' {
        96kb | into int
    } else if $audio_codec == 'aac' {
        128kb | into int
    } else {
        error make {
            msg: "codec must be 'aac' or 'opus'"
        }
    }
    let filesize_bits = ($filesize | into int) * 8 # Total bits
    let total_bitrate = ($filesize_bits / $duration) | into int | $in * $FALLIBILITY_THRESHOLD
    let video_bitrate = $total_bitrate - $audio_bitrate

    if ($target | path exists) {
        return
    }

    # First Pass
    (ffmpeg
        -v quiet
        -stats
        -y
        -i $path
        -c:v libx265
        -b:v $video_bitrate
        -pass 1
        -preset veryfast
        -x265-params "log-level=error"
        -an
        -f null /dev/null
    )

    # Second Pass
    (ffmpeg
        -v quiet
        -stats
        -y
        -i $path
        -c:v libx265
        -b:v $video_bitrate
        -pass 2
        -preset $preset
        -x265-params "log-level=error"
        ...(if $no_audio {
            ['-an']
        } else {
            [ -c:a, (if $audio_codec == 'opus' { 'libopus' } else { 'aac' }), -b:a, $audio_bitrate ]
        })
        -vf $"scale=($scale.max_width):($scale.max_height)"
        $target
    )
}

export def 'vid 2p vp9' [
    path: path,
    filesize?: filesize,
] {
    let exact = $filesize != null
    let filesize = if $filesize == null { 10mib } else { $filesize }
    let FALLIBILITY_THRESHOLD = if $exact { 1 } else { 0.95 }

    let scale = vid get-default-scaling $path
    let target = vid get-default-filename $path --ext webm
    let meta = vid get-meta $path
    let duration = $meta.duration | into int | $in / 1000000000 # micros in 1sec
    let audio_bitrate = 96 * 1000 # 96 kbps in bits per second

    let filesize_bits = ($filesize | into int) * 8 # Total bits
    let total_bitrate = ($filesize_bits / $duration) | into int | $in * $FALLIBILITY_THRESHOLD
    let video_bitrate = $total_bitrate - $audio_bitrate

    if ($target | path exists) {
        return
    }

    # First pass
    (ffmpeg
        -v quiet
        -stats
        -y
        -i $path
        -c:v libvpx-vp9
        -b:v $video_bitrate
        -pass 1
        -cpu-used 4
        -tile-columns 3
        -an
        -f null /dev/null
    )

    # Second pass
    (ffmpeg
        -v quiet
        -stats
        -i $path
        -c:v libvpx-vp9
        -b:v $video_bitrate
        -pass 2
        -cpu-used 4
        -tile-columns 3
        -c:a libopus
        -b:a $audio_bitrate
        -vf $"scale=($scale.max_width):($scale.max_height)"
        $target
    )
}

export def 'vid remote-encode' [
    path: path
] {
    let filename = $path | path basename
    let target = vid get-default-filename $path
    if ($target | path exists) {
        return
    }

    let elapsed_upload = timeit { ssh cp $path "worker:Downloads/encodes/" }
    print -e $"upload took (ansi yellow)($elapsed_upload)(ansi reset)"


    let start = "let v = from json; cd Downloads/encodes; vid h265-encode $v.filename"
    let elapsed_encode = timeit {
        { filename: $filename }
            | to json
            | ssh worker $"nu --stdin --config .config/nushell/config.nu -c \"($start)\""
    }
    print -e $"encode took (ansi yellow)($elapsed_encode)(ansi reset)"

    let elapsed_download = timeit { ssh cp $"worker:Downloads/encodes/($target)" $target }
    print -e $"download took (ansi yellow)($elapsed_download)(ansi reset)"

    let remove = "let v = from json; cd Downloads/encodes; rm $v.filename"
    { filename: $filename } | to json
        | ssh worker $'nu --stdin -c "($remove)"'
}

def dither-algorithms [] {
    [
        'none',
        'atkinson',
        'bayer',
        'burkes',
        'floyd_steinberg',
        'heckbert',
        'sierra2',
        'sierra2_4a',
        'sierra3'
    ]
}

export def 'vid to-gif' [
    file: path
    output?: path
    --fps: int # = 50
    --start: string
    --end: string
    --height: int
    --width: int
    --loops: int = 0 # -1 to not repeat, 0 to repeat forever, 1+ for counts
    --dither: string@dither-algorithms # none/atkinson/bayer/burkes/floyd_steinberg/heckbert/sierra2/sierra2_4a/sierra3
    --framepalettes # New palette per frame, for most varying colors, highly ruining compression
    --crop: string # w:h:x:y
] {
    let output = $output | default (path interject $file --ext gif --count)
    let parsed = $file | path parse
    let fps = if $parsed.extension in ['png', 'jpg', 'jpeg'] {
        25 # Image input is interpreted as 25fps video with one frame
    } else {
        $fps
    }
    # Use -1, -2, -4 to keep multiples when rounding and automatically calculating the other dimension
    let height = $height | default (-1)
    let width = $width | default (-1)
    let dithercommand = if $dither != null {
        $":dither=($dither)"
    } else {
        ""
    }
    let fpsfilter = if $fps != null {
        $"fps=($fps),"
    } else {
        ""
    }
    let cropfilter = if $crop != null {
        $"crop=($crop),"
    } else {
        ""
    }
    # Using the colorspace filter ONLY for palettegen seems to churn out more accurate results
    # Currently unused due to some input files having "unknown" color space, which makes mapping impossible
    let colorspacefilter = "colorspace=all=bt709:trc=srgb:range=pc"
    let palettefilter = $"paletteuse=new=($framepalettes | into int)($dithercommand)"
    let palettegen = $"palettegen=stats_mode=(if $framepalettes { 'single' } else { 'full' })"

    let filter = $"($fpsfilter)($cropfilter)scale=($width):($height):flags=lanczos,split[s0][s1];[s0]($palettegen)[p];[s1][p]($palettefilter)"

    print $filter

    (ffmpeg
        # ...(if $start != null { [-ss, $start] } else { [] })
        # ...(if $end != null { [-t, $end] } else { [] })
        ...(if $start != null { [-ss $start] } else { [] })
        ...(if $end != null { [-to $end] } else { [] })
        -i $file
        -vf $filter
        -loop $loops
        $output
    )
}

# export def position-gif-transparent [
#     file: path
#     --width: int
#     --height: int
#     --x: int
#     --y: int
#     --frame-width: int
#     --frame-height: int
#     --background: string = '0x00000000'
# ] {
#     let output = path interject $file positioned
#     let meta = vid get-meta $file
#     let fps = $meta.fps | into int
#     let frames = $meta.frames
#     let duration_secs = $meta.duration | into int | $in / 1000000000

#     (ffmpeg
#         -i $file
#         -filter_complex $"[0:v]scale=($width):($height)[resized];
#         color=($background):s=($frame_width)x($frame_height):d=($duration_secs),fps=($fps)[bg];
#         [bg][resized]overlay=($x):($y):shortest=0"
#         -c:v gif
#         $output
#     )
# }

export def 'vid position-gif-transparent' [
    file: path
    --width: int
    --height: int
    --x: int
    --y: int
    --frame-width: int
    --frame-height: int
    --background: string = '0x00000000'
] {
    let output = path interject $file positioned
    let palette = path interject $file "palette" --ext png
    let meta = vid get-meta $file
    let fps = $meta.fps | into int
    let frames = $meta.frames
    let duration_secs = ($meta.duration | into int) / 1000000000

    # Palettegen for transparency
    (ffmpeg
        -i $file
        -filter_complex $"
            [0:v]fps=($fps),scale=($width):($height)[resized];
            color=($background):s=($frame_width)x($frame_height):d=($duration_secs),fps=($fps)[bg];
            [bg][resized]overlay=($x):($y):shortest=0,fps=($fps),palettegen=reserve_transparent=1"
        -y $palette
    )

    # Generate file and position it
    (ffmpeg
        -i $file
        -i $palette
        -filter_complex $"
            [0:v]fps=($fps),scale=($width):($height)[resized];
            color=($background):s=($frame_width)x($frame_height):d=($duration_secs),fps=($fps)[bg];
            [bg][resized]overlay=($x):($y):shortest=0,fps=($fps)[out];
            [out][1:v]paletteuse=dither=bayer:bayer_scale=5"
        -loop 0
        -y
        $output
    )

    rm $palette
}

export def 'vid get-default-filename' [file: path, target?: path, --ext: string = 'mp4'] {
    let parsed_file = $file | path parse

    # let target = $target | default ($parsed_file.stem + ".min." + $parsed_file.extension)
    let target = $target | default ($parsed_file.stem + ".min." + $ext)

    return $target
}

export def "vid min gpu" [
    file: path # The path to the video
    bitrate_per_second: filesize = 1.5mb # The target video bitrate. mb = mbits. Nvenc tends to lowball, so make this higher than max
    target?: path # The target filename
    --preset: string = "p7" # The encoding preset to use
    --res-y: int # The target video height in pixels
    --res-x: int # The target video width in pixels
] {
    let target = vid get-default-filename $file $target

    let target_video_bitrate_argument = $"($bitrate_per_second / 1kb)K"

    let target_video_filter = if $res_x == null and $res_y == null {
        let scale = vid get-default-scaling $file

        $"scale=($scale.max_width | default (-2)):($scale.max_height | default (-2))"
    } else {
        $"scale=($res_x | default (-2)):($res_y | default (-2))"
    }

    # print "filter: " + $target_video_filter

    ^ffmpeg ...[
        -v quiet # No banner, metadata, streams
        -stats # Show progress bar
        # -hwaccel cuda # redundant?
        # -hwaccel_output_format cuda Full hardware doesn't support filters for resize, also isn't really faster?
        -i $file
        -c:v hevc_nvenc
        # -pix_fmt yuv420p # Output format supported by the GPU; redundant
        -preset $preset
        -rc vbr
        -multipass 2
        -tune hq
        ...(if $target_video_filter != '' { ['-vf', $target_video_filter] } else { [] })
        -b:v $target_video_bitrate_argument
        -bufsize 10M
        -c:a copy # copy audio; otherwise just aac 128k
        -y
        $target
    ]
}

export def "vid min many" [
    paths: list
    --bitrate: filesize = 1.5mb # Bits per second
    --threads(-t): int = 4
    --delete(-d) # Delete source files if larger than converted file
] {
    # Clear terminal but without losing data
    term clear-spaced

    let rows_mutex = mutex make
    let print_mutex = mutex make

    let instance_key = random chars

    stor open | query db "CREATE TABLE IF NOT EXISTS vid_min_rows (
        instance_id TEXT NOT NULL,
        position INTEGER NOT NULL
    )"

    $paths | enumerate | par-each -t $threads { |pair|
        let free_position = mutex with $rows_mutex {
            let taken_positions = (stor open
                | query db $"SELECT * FROM vid_min_rows WHERE instance_id = '($instance_key)'"
                | get position
            )

            let free_position = 0..1000 | where { |n| $n not-in $taken_positions } | first

            stor insert -t vid_min_rows -d { instance_id: $instance_key, position: $free_position }

            $free_position
        }

        # sleep (random int 0..5000 | into duration -u ms)

        let basename = $pair.item | path basename
        let scale = vid get-default-scaling $pair.item
        let target = vid get-default-filename $pair.item

        vid min gpu $pair.item $bitrate $target --res-y $scale.max_height --res-x $scale.max_width e>| reduce -f 1 { |chunk, column|
            let terminal_height = (term size | get rows) - 3

            let prefix = if $column == 1 {
                $"[($basename)] "
            } else {
                ""
            }

            let chunk = $"($prefix)($chunk)"

            mutex with $print_mutex {
                term move-cursor ($column - 1) ($free_position + 1)
                if $column == 1 {
                    # term clear-rest-of-line
                    # term move-cursor ($column - 1) ($free_position + 1)
                }

                print -n $chunk
            }

            let new_column = if ($chunk | str contains "\r") { 1 } else { $column + ($chunk | str length) }

            $new_column
        } | ignore

        try {
            let old_size = ls -D $pair.item | get size.0
            let new_size = ls -D $target | get size.0

            if $old_size > $new_size and $delete {
                rm $pair.item
            }
        }

        stor open | query db $"DELETE FROM vid_min_rows WHERE instance_id = ? AND position = ?" -p [$instance_key, $free_position]
    } | ignore
}

export def "vid min folder" [
    --glob: string = "**/*.{mp4,webm,mkv,avi,m4v,mpg,wmv,flv,mov}",
    --bitrate: filesize = 1.5mb # Bits per second
    --delete(-d) # Delete source files if larger than converted file
    --threads(-t): int = 4
] {
    let paths = glob $glob -DS | where $it !~ '.min.\w+'

    vid min many $paths --threads $threads --bitrate $bitrate --delete=$delete
}

export def 'vid validate' [
    path: path
] {
    let results = ffmpeg  -loglevel 24 -hide_banner -i $path -c:v copy -c:a copy -f null - | complete

    if $results.exit_code != 0 or $results.stderr != "" {
        return { ok: false, message: $results.stderr }
    } else {
        return { ok: true, message: null }
    }
}

export def "vid validate folder" [
    --glob: string = "**/*.{mp4,webm,mkv,avi,m4v,mpg,wmv,flv,mov}"
    --threads(-t): int = 1
] {
    timeit {
        glob $glob | par-each -t $threads { |path|
            let base = $path | path basename

            print -en $"\rValidating ($base)..."
            term clear-rest-of-line

            let valid = vid validate $path

            if not $valid.ok {
                print -en "\r"
                term clear-rest-of-line
                print $"\rInvalid file: ($base)\n($valid.message)"
            }
        }

        print
    }
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

# Cuts a video from `start` to `end`, in nvenc p7 h265, with optional size target
export def vcut [
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
