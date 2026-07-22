use _fs.nu
use _dev.nu

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

export def 'ocr scan' [] {
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

    if ($start_dataset | describe -d | get type) == 'list' {
        $start_dataset = {}
    }

    let start_dataset = $start_dataset

    glob '**/*.{jpg,jpeg,png}' | path relative-to $env.PWD | enumerate | par-each -t 4 { |item|
        let path = $item.item
        let index = $item.index

        let meta = ls -D $path | first
        # Do not query per file
        # let existing = $handle | query db "SELECT * FROM ocr_results_v0 WHERE path = ?" -p [$path] | get 0?
        let existing = $start_dataset | get -o $path
        let clear_bar = '' | fill -w (term size | get columns) -c ' '

        if $existing == null or ($existing | into datetime) < $meta.modified {
            let ocr_result = ocrs $path | complete

            if $ocr_result.exit_code != 0 {
                print -e $ocr_result.stderr
                return
            }

            # print $ocr_result.stdout
            let text = $ocr_result.stdout | str trim
            let char_count = $text | str length
            print $"\r($clear_bar)\r($path) \(($index)) \(($char_count) chars)" -n

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
