use _combinators.nu *

export def greplink [
	files: string # Glob pattern for files to search in
	regex: string # The regex to test the files' content against
	target: string # The target folder to copy files that match into
	--delete(-d) # Delete the folder before copying
    --threads(-t): int = 16 # The level of parallelism
    --hard
] {
    if $delete {
        rm -rf $target
    }

    mkdir $target

    let existing = do {
        cd $target
        glob * -FD
    }

    if ($existing | is-not-empty) {
        print $"There are ($existing | length) symlinks in the folder. Deleting them"

        $existing | par-each { |path| rm $path }
    }

    # no dirs, no symlinks
    # glob -DS $files | par-each-spawn --threads $threads { |path, ctx|
    #     let matched = open $path --raw | decode utf-8 | parse -r $ctx.regex | is-not-empty

    #     if $matched {
    #         let size = ls -D $path | get 0.size
    #         mut base = $path | path basename
    #         mut link_path = $ctx.target | path join $base
    #         for i in 1.. {
    #             if not ($link_path | path exists) {
    #                 break
    #             }
    #             let parsed = $path | path parse
    #             $base = $"($parsed.stem).($i).($parsed.extension)"
    #             $link_path = $ctx.target | path join $base
    #         }

	# 		print -e $"Linking: (ansi yellow)($base)(ansi reset) \((ansi green)($size)(ansi reset)\)"

    #         mklink $link_path $path | ignore
    #         touch $link_path -m -s -r $path
    #     }
    # } { regex: $regex, target: $target } | ignore
    glob -DS $files | par-each --threads $threads { |path|
        let matched = open $path --raw | decode utf-8 | parse --backtrack 1_000_000_000 -r $regex | is-not-empty

        if $matched {
            let size = ls -D $path | get 0.size
            mut base = $path | path basename
            mut link_path = $target | path join $base
            for i in 1.. {
                if not ($link_path | path exists) {
                    break
                }
                let parsed = $path | path parse
                $base = $"($parsed.stem).($i).($parsed.extension)"
                $link_path = $target | path join $base
            }

			print -e $"Linking: (ansi yellow)($base)(ansi reset) \((ansi green)($size)(ansi reset)\)"

            try {
                ml --hard=$hard $link_path $path | ignore
            } catch { |e|
                print $"error: ($e)"
            }
            # touch $link_path -m -s -r $path
        }
    } | ignore
}


const CREATE_FILE_HASHES = "
    CREATE TABLE IF NOT EXISTS file_hashes (
        file_path TEXT PRIMARY KEY,
        file_size INTEGER NOT NULL,
        hash_hex STRING
    )
"

# REPLACE INTO but with manual null coalescing
const INSERT_FILE_HASHES = "
    INSERT INTO file_hashes (file_path, file_size, hash_hex)
    VALUES (?, ?, ?)
    ON CONFLICT(file_path) DO UPDATE SET
        file_size = COALESCE(excluded.file_size, file_hashes.file_size),
        hash_hex = COALESCE(excluded.hash_hex, file_hashes.hash_hex);
"
const SELECT_FILE_SIZE_COLLISIONS = "
    SELECT
        COUNT(*) AS countitude,
        file_size
    FROM file_hashes
    GROUP BY file_size
    HAVING countitude > 1
"
const SELECT_FILE_HASHES_BY_SIZE = "
    SELECT *
    FROM file_hashes
    WHERE file_size = ?
"
const SELECT_FILE_HASHES = "
    SELECT * FROM file_hashes
"
const SELECT_HASH_COLLISIONS = "
    SELECT
        COUNT(*) AS countitude,
        hash_hex
    FROM file_hashes
    WHERE hash_hex IS NOT NULL
    GROUP BY hash_hex
    HAVING countitude > 1
"

export def scan-file-hashes [
    glob: string = '**/*'
    --noexpand
] {
    stor open | query db $CREATE_FILE_HASHES

    # note: par-each can data race in-memory sqlite dbs
    # so like, be careful (?)
    let count = glob $glob -DS | par-each { |p|
        let p = if $noexpand { $p } else { $p | path expand }
        let meta = ls -D $p | first

        # null does not override existing hash
        stor open | query db $INSERT_FILE_HASHES -p [$p $meta.size null]
    } | length

    print -e $"added: ($count) files to scan list \(run fill-file-hashes to sieve)"
}

export def fill-file-hashes [] {
    stor open | query db $SELECT_FILE_SIZE_COLLISIONS | each { |row|
        let files = stor open | query db $SELECT_FILE_HASHES_BY_SIZE -p [$row.file_size]

        print -e $"file size collision group with length: ($files | length), size: ($row.file_size * 1b)"

        $files | each { |row|
            print -e $"file path: ($row.file_path)"
        }

        $files | each { |row|
            if $row.hash_hex != null {
                print -e $"hash was already computed: ($row.hash_hex)"
                return
            }

            let hash = open $row.file_path --raw | hash sha256

            print -e $"computed hash: ($hash)"

            stor open | query db $INSERT_FILE_HASHES -p [$row.file_path $row.file_size $hash]
        }
    }

    let duplicate_hashes = stor open | query db $SELECT_HASH_COLLISIONS | get hash_hex

    (stor open
        | query db $SELECT_FILE_HASHES
        | where { |row| $row.hash_hex in $duplicate_hashes }
        | group-by hash_hex
        | update cells { reject hash_hex }
        | values
    )
}

export def newest-file [] {
    ls | sort-by modified -r | first | get name
}

export def extract-imgs [ filename: string ] {
    let parsed = $filename | path parse
    let src = open $filename -r
    let starts = $src | bytes index-of (bytes build 0x[89] ("PNG" | into binary)) -a
    let ends = $src | bytes index-of ("IEND" | into binary) -a
    let pairs = $starts | zip $ends | skip 1

    $pairs | each { |p| $src | bytes at ($p.0)..($p.1 + 4) | save $"($parsed.stem).($p.0).($p.1).png" }

    $pairs
}

export def fix-image-extensions [] {
    glob **/* -DS | par-each -k { |path|
        let p = $path | path parse
        let bytes = open $path --raw | bytes at 0..3
        let is_png = $bytes == 0x[89 50 4e 47]

        if $is_png and $p.extension != png {
            mv $path ($p | update extension png | path join)
        }
    }
}

# Symlinks, /D if $target is directory
# Might require admin if you don't enable developer mode or tweak UAR
export def ml [
    source: path, # The path the symlink will live at
    target: path # The path the symlink will point to
    --force(-f)
    --clobber
    --hard
] {
    let source_path = $source | path expand
    let target_path = $target | path expand

    mut dont_copy_meta = true
    mut rm_before_mklink = false

    if ($source_path | path exists -n) {
        if not $clobber {
            error make {
                msg: (
                    "Source path exists. Make sure the symlink is the first argument, and the target is the second.\n"
                    + "If you want to overwrite a source path, use --clobber"
                ),
                label: {
                    text: 'this path',
                    span: (metadata $source).span
                }
            }
        } else {
            $rm_before_mklink = true
        }
    }

    let target_stat = try {
        let stat = ls -D $target | first

        $dont_copy_meta = false

        $stat
    } catch {
        if $force {
            # Let's make it up as we go
            {
                type: 'file'
            }
        } else {
            error make {
                msg: (
                    "Target does not exist. Make sure the symlink is the first argument, and the target is the second.\n"
                    + "If a non-existent target is desired, use --force"
                ),
                label: {
                    text: 'this path',
                    span: (metadata $target).span
                }
            }
        }
    }

    if $rm_before_mklink {
        # rm doesn't seem to follow symlinks
        rm $source
    }

    let result = if $target_stat.type == 'dir' {
        mklink /D $source $target | complete
    } else {
        mklink ...(if $hard { [ '/H' ] }) $'"($source)"' $'"($target)"' | complete
    }

    if $result.exit_code != 0 {
        error make {
            msg: $result.stderr
        }
    }

    if not $dont_copy_meta {
        touch $source -c -s -r $target
    }
}

export def make-tl-fold [ folder: path ] {
    mkdir $folder

    # print -e "Matching *direct children images* for timelines"
    print -e "Matching *subtree images* for timelines"
    time { greplink **/*.png 'interpolable|<keyframe|<curveKeyframe' $folder } "grep linking"

    print -e "Filtering out non-timeline false positives"
    cd $folder
    mkdir .fakes

    time {
        glob *.png | par-each { |file|
            if not (is-timeline $file) {
                print $"fake: ($file)"
                # mv does not follow symlinks, cp does
                mv $file ('.fakes' | path join ($file | path basename))
                # rm $file
            }
        }
    } "sieving"

    mkdir .edits

    # yyyy_mmdd_hhmm_ss_SSS.png, -DF should be redundant
    glob ????_????_????_??_???.png -DF | par-each { |file|
        let base = $file | path basename
        let resolved = $file | path expand
        let dir_base = $resolved | path dirname | path basename

        if $dir_base =~ '-scene' {
            ml $"./.edits/($base)" $resolved
        }
    } | ignore
}

export def is-timeline [ path: path, --debug ] {
    try {
        let xml = open --raw $path | decode utf-8 | parse -r '(<root\s+(?:duration|time|block|division)[\s\S]*?</root>)' | last | get capture0 | from xml

        if $debug {
            $xml | table -e | print
        }

        $xml.content | any { |tag| is-tag-worthwhile $tag }
    } catch {
        return false
    }
}

def is-tag-worthwhile [ tag, --depth: int = 0 ]: [any -> bool] {
    # Camera and time scale keyframes are pretty uninteresting
    if $tag.tag == 'interpolable' and $tag.attributes.id =~ "camera|timeScale" {
        return false
    }

    if $tag.tag == 'interpolableGroup' {
        let is_worthwhile = ($tag.content | is-not-empty) and ($tag.content | any { |tag| is-tag-worthwhile $tag --depth ($depth + 1) })
        return $is_worthwhile
    }

    # IDK what we're dealing with, might be important
    # print $"ok: ($tag.tag)"
    return true
}

# alias glob-original = glob
# export def glob [
#     glob: string # The glob expression.
#     --depth(-d): int # directory depth to search
#     --no-dir(-D) # Whether to filter out directories from the returned paths
#     --no-file(-F) # Whether to filter out files from the returned paths
#     --no-symlink(-S) # Whether to filter out symlinks from the returned paths
#     --exclude(-e): list<string> # Patterns to exclude from the search: `glob` will not walk the inside of directories matching the excluded patterns.
# ] {
#     let parsed = $glob | path parse
#     let glob = if $parsed.prefix != '' {
#         # if blocks don't have scoped env; the command does
#         let root = $"($parsed.prefix)(char psep)"
#         cd $root

#         $glob | path relative-to $root | str replace -a (char psep) '/'
#     } else {
#         $glob | str replace -a (char psep) '/'
#     }
#     let depth = if $depth == null {
#         # Optimize default depth as much as we can, since we can't pass in a null with --depth=$depth
#         if ($glob | str contains "**") {
#             65536
#         } else {
#             # Something like /{a/b,c/d}/ will be overcounted with this strategy
#             $glob | path split | length
#         }
#     } else {
#         $depth
#     }

#     glob-original $glob --depth=$depth --no-dir=$no_dir --no-file=$no_file --no-symlink=$no_symlink --exclude=$exclude
# }

# Normalized explorer command
export def explorer [
	path: string = "." # Path of folder to open in file explorer
] {
	if ($path | path exists) {
		let path_type = ($path | path expand | path type)

		if $path_type == 'dir' {
			cd $path; explorer.exe .
		} else {
			echo $"(ansi red)The path you provided is not a directory."
			echo $"(ansi red)You passed: ($path)"
			echo $"(ansi red)It is: ($path_type)"
		}
	} else {
		# Sad path :(
		# Find first path segment that does not exist
		# let expanded_split = ($path| path split | reduce -f [] { |seg, parts|
		# 	$parts | append [($parts | last | append $seg)]
		# })
		# let expanded_paths = ($expanded_split | each { |parts| $parts | path join })
		# let paths_that_exist = ($expanded_paths | each while { |path|
		# 	if ($path | path exists) {
		# 		$path
		# 	} else {
		# 		null
		# 	}
		# })
		# let the_path_after_the_last_one_that_exists = ($expanded_paths | get ($paths_that_exist | length))

		# echo $"(ansi red)The path you provided does not exist."
		# echo $"(ansi red)You passed: ($path)"
		# echo $"(ansi red)First directory that doesn't exist: ($the_path_after_the_last_one_that_exists)"
        echo 'noexist'
	}
}

export def 'list-hashes' [] {
    glob **/* -D | par-each { |path|
        let relative = path relative-to $env.PWD
        let hash = open $path --raw | hash sha256

        {
            path: $relative,
            hash: $hash
        }
    }
}

export def 'du-native' [] {
    ^du -ab | lines | parse -r '(?<bytes>\d+)\s+(?<path>.+)' | update bytes { into int | $in * 1b }
}

export def 'ls-recursive-native' [] {
    ^ls -R | lines | generate { |line, state = { ready: true, path: null }|
        if $state.ready == true {
            return {
                out: null,
                next: {
                    ready: false,
                    path: ($line | parse -r '(?<path>.+):' | first | get path)
                }
            }
        }

        if $line == '' {
            return {
                out: null,
                next: {
                    ready: true,
                    path: null
                }
            }
        }

        return {
            out: ($state.path | path join $line),
            next: $state
        }
    } | where $it != null
}

export def find-all-files [] {
    ^'C:\Program Files\Git\usr\bin\find.exe' . -type f | lines
}

export def cp-symlinks [
    from: string
    to: string
    --force
] {
    let from_abs = $from | path expand
    let to_abs = $to | path expand

    let symlinks = do {
        cd $from_abs

        ls **/* -l | where type == symlink | sort-by modified | select name target
    }

    print $symlinks

    # This copies folders, so always make the folder
    mkdir $to

    $symlinks | each { |sym|
        ml ($to | path join $sym.name) $sym.target --force=$force
    }
}

export def distribute-hashed-files [
    root
    --limit: int = 1
] {
    take $limit | par-each { |row|
        let target_dir = $'($root)\($row.hash | str substring 0..1)\($row.hash | str substring 2..2)'
        let target_path = $target_dir | path join $"($row.hash).png"
        mkdir $target_dir

        try {
            mv $row.path $target_path

            ml $row.path $target_path --hard
        } catch { |e|
            print $"($row.path)"
        }

        null
    }
}
