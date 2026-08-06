use _fs.nu *
use _dev.nu *
use _term.nu *

def create-db-if-missing [] {
    let exists = '!ocr.db' | path exists

    if not $exists {
        { x: 'y' } | into sqlite !ocr.db -t sentinel
    }
}

const CREATE_OCR_STMT = "
    CREATE TABLE IF NOT EXISTS ocr_results_v0 (
        path TEXT PRIMARY KEY,
        recognized_text TEXT NOT NULL,
        last_checked DATETIME NOT NULL
    )
"
const INSERT_OCR_STMT = "
    REPLACE INTO ocr_results_v0 (path, recognized_text, last_checked)
    VALUES (:path, :text, :modified)
"

export def 'ocr umi' [ path: string, --retries: int = 4 ] {
    # Local patch
    $env.UMI_QUIET = 1

    let expanded = $path | path expand
    let output_path = mktemp --dry

    for i in 0..<$retries {
        Umi-OCR --output $output_path --path $expanded

        if not ($output_path | path exists) {
            sleep 0.1sec
            continue
        }

        let text = open $output_path

        rm $output_path

        return $text
    }

    error make {
        msg: 'Umi-OCR could not extract any text'
    }
}

export def 'ocr ocrs' [ path: string ] {
    ocrs $path
}

export def 'ocr scan' [
    --threads: int = 4
    --engine: string = "umi"
    --nopreviews
] {
    create-db-if-missing

    open !ocr.db | query db "
        CREATE TABLE IF NOT EXISTS ocr_results_v0 (
            path TEXT PRIMARY KEY,
            recognized_text TEXT NOT NULL,
            last_checked DATETIME NOT NULL
        )
    "

    # 30% faster, despite sqlite handles simply opening a connection for each statement
    let handle = open !ocr.db
    # Importing full and keeping in memory is much faster for normal amounts of files
    # (up to ~100% faster at ~30000 images)
    mut start_dataset = $handle | query db "SELECT path, last_checked FROM ocr_results_v0" | transpose -rd

    let ocr_fn = if $engine == "umi" {
        { |p| ocr umi $p }
    } else {
        { |p| ocr ocrs $p }
    }

    if ($start_dataset | describe -d | get type) == 'list' {
        $start_dataset = {}
    }

    let start_dataset = $start_dataset

    if not $nopreviews {
        clear -k;
    }

    glob '**/*.{jpg,jpeg,png}' | path relative-to $env.PWD | enumerate | par-each -t $threads { |item|
        let path = $item.item
        let index = $item.index

        let meta = ls -D $path | first
        # Do not query per file
        # let existing = $handle | query db "SELECT * FROM ocr_results_v0 WHERE path = ?" -p [$path] | get 0?
        let existing = $start_dataset | get -o $path
        let clear_bar = '' | fill -w (term size | get columns) -c ' '

        # TODO: webp/avif to temp jpeg
        let image_path = $path

        if $existing == null or ($existing | into datetime) < $meta.modified {
            let ocr_result = try {
                do $ocr_fn $image_path
            } catch { |e|
                print -e $"\nerror while ocring ($path) ($e)\n"
                return
            }

            let text = $ocr_result | str trim -r
            let char_count = $text | str length

            if $nopreviews {
                print $"\r($clear_bar)\r($path) \(($index)) \(($char_count) chars)" -n
            } else {
                clear

                term print-at 0 1 $"($path) \(($index)) \(($char_count) chars)\e[K\n\n"

                let sz = term size
                let head = $ocr_result | str replace -ar $".{($sz.columns)}" '$0\n' | lines | take ($sz.rows - 6) | str join "\n"

                print $head
            }

            $handle | query db $INSERT_OCR_STMT -p {
                path: $path,
                text: $text,
                modified: $meta.modified
            }

            null
        } else {
            print $"\r($clear_bar)\r($path) \(($index)) \(cached)" -n
        }
    }

    null
}

export def 'ocr search' [
    ...keywords
    --open
    --regex(-r)
    --print
] {
    # Importing the whole table is very fast, so reducing throughput by filtering
    # in the query would be meaningless. It might optimize the keyword search though,
    # but I don't think sqlite comes with a decent regex implementation
    let results = open !ocr.db | query db "SELECT * FROM ocr_results_v0"

    let filtered = $results
        | par-each { |row|
            let is_match = $keywords | all { |kw|
                if $regex {
                    $row.recognized_text | parse -r $kw | is-not-empty
                } else {
                    # Case insensitive by default !!!
                    $row.recognized_text | str contains -i $kw
                }
            }

            if $is_match { $row } else { null }
        }
        | sort-by -r { |row| $row.recognized_text | str length }

    if ($filtered | is-empty) {
        print $"No ocr matches found. \(($results | length) entries in ocr database\)"
        return
    }

    if $print {
        let pad = $filtered.path | each { str length } | math max

        $filtered | each { |row|
            let ansi_text = $keywords | reduce -f $row.recognized_text { |kw, text|
                $text | str replace -a --regex=$regex $kw $"(ansi red)(if $regex { '$0' } else { $kw })(ansi reset)"
            } | str trim

            print $"($row.path)    " -n
            print ($ansi_text | str replace -a "\n" $"\n('' | fill -w ($pad + 4) -c ' ')")
        }
    } else {
        let dir = mktemp -dt tmpocr.XXXXXXXXXX

        # Surprisingly slow. par-each messes up modified timestamp ordering but ImageGlass uses name order
        let symlink_paths = $filtered | reverse | enumerate | par-each { |pair|
            let expanded = $pair.item.path | path expand
            let prefixed = $"($pair.index | fill -a r -w 4 -c 0).($pair.item.path | path basename)"
            let target = $dir | path join $prefixed

            if not ($expanded | path exists) {
                return
            }

            ml $target $expanded

            $target
        }

        ^'C:\Program Files\ImageGlass\ImageGlass.exe' ($symlink_paths | first)

        print "deleting temp folder"

        rm -r $dir
    }
}
