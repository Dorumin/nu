use _sqlite.nu *

export def time [
    closure: closure,
    label?: string
] {
    let start = (date now)
    let result = (do $closure)
    let end = (date now)
    let difference = ($end - $start)

    if $label != null {
        print $"($label) took ($difference)"
    } else {
        print $difference
    }

    $result
}

export def type-of [v] {
    $v | describe -d | get type
}

export def type-is [v, ty: string] {
    (type-of $v) == $ty
}

export def do-spawn [ clos: closure ] {
    nu --stdin -c $"do (view source $clos)"
}

export def far-each [ map: closure, --threads: int = 16 ] {
    let list = $in | enumerate # I forgot how to store streaming input
    let dad = job id
    let seed = random int 100000..1000000000

    let workers = 0..<$threads | each {
        job spawn {
            loop {
                let arg = job recv
                let v = do $map $arg.item $arg.index
                $v | job send $dad --tag ($seed + $arg.index)
            }
        }
    }

    $list | each { |pair|
        let worker = $workers | get ($pair.index mod $threads)
        $pair | job send $worker
    }

    let results = $list | each { |pair| job recv --tag ($seed + $pair.index) }

    $workers | each { |worker| job kill $worker }

    $results
}

export def par-each-spawn [ close: closure, ctx: any, --threads: int = 8, --batch: int = 8 ] {
    chunks $batch | par-each { |chunk|
        let handle_batch = { ||
            let data = from json
            let chunk = $data.chunk
            let ctx = $data.ctx

            $chunk | each { |item| do $env.CODEX $item $ctx } | to json
        }

        { ctx: $ctx, chunk: $chunk } | to json
            | nu --login --stdin -c $"do (view source $handle_batch | str replace "$env.CODEX" (view source $close))"
            | from json
    } | flatten
}

export def parallel [ ...closures: oneof<closure, list> ] {
    # Allow a closure or array of closures as input
    let flat = $closures | flatten

    $flat | par-each -k -t ($flat | length) {
        |c| do $c
    }
}

export def these-files-are-made-for-walkin [ closer: closure, cwd = '.' ] {
    let files = ls -f $cwd

    $files | each { |row|
        let deeper = do $closer $row

        if $row.type == 'dir' and $deeper != false {
            these-files-are-made-for-walkin $closer $row.name
        }
    }
}

# Traverse a deeply nested structure, mapping any non-collection value
export def traverse [
    mapper: closure,
    path: cell-path = $.
] {
    let input = $in
    let ty = ($input | describe -d).type

    if ($ty == "record") {
        $input | transpose k v | update v { |row|
            let inner_path = $path | to json | from json | append $row.k | into cell-path

            $row.v | traverse $mapper $inner_path
        } | transpose -rd
    } else if ($ty == "list") {
        $input | enumerate | each { |pair|
            let inner_path = $path | to json | from json | append $pair.index | into cell-path

            $pair.item | traverse $mapper $inner_path
        }
    } else if ($ty == "table") {
        error make {
            msg: "describe never returns table"
        }
    } else {
        do $mapper $input $path
    }
}

# Combinator to map a value if an optional argument is present
export def then [
    optional
    updater
] {
    let input = $in

    if $input == null {
        error make { msg: "you probably want to pass in a value" }
    }

    if ($optional | is-not-empty) {
        $input | do $updater $optional
    } else {
        $input
    }
}

export def map-with-last [
    mapper: closure
    --buffer: int = 1
]: [list -> list] {
    prepend (0..<$buffer | each -k { null })
        | window ($buffer + 1)
        | each { |win|
            let row = $win | last
            let last = $win | take $buffer

            do $mapper $row $last
        }
        | skip $buffer
}

export def collate [
    append
    --db: path = ($nu.temp-dir | path join collated.db)
    --wait: duration = 1sec
    --interval: duration = 0.1sec
] {
    let self_ident = random uuid

    sqlite init $db [
        "
            CREATE TABLE IF NOT EXISTS collate_values (
                value TEXT,
                inserted_at DATETIME NOT NULL,
                taken_by TEXT
            )
        "
        "
            CREATE INDEX IF NOT EXISTS collate_index ON collate_values( taken_by, inserted_at )
        "
    ]

    # print (open $db | query db "EXPLAIN QUERY PLAN INSERT INTO collate_values (value, inserted_at, taken_by) VALUES (?, ?, ?)" -p [($append | to json), (date now), null])
    # print (open $db | query db "EXPLAIN QUERY PLAN SELECT MAX(inserted_at) AS latest FROM collate_values WHERE taken_by IS NULL")
    # print (open $db | query db "EXPLAIN QUERY PLAN UPDATE collate_values SET taken_by = ? WHERE taken_by IS NULL" -p [$self_ident])
    # print (open $db | query db "EXPLAIN QUERY PLAN SELECT value, inserted_at FROM collate_values WHERE taken_by = ?" -p [$self_ident])

    open $db | query db "INSERT INTO collate_values (value, inserted_at, taken_by) VALUES (?, ?, ?)" -p [($append | to json), (date now), null]

    loop {
        sleep $interval

        let latest = open $db | query db "SELECT MAX(inserted_at) AS latest FROM collate_values WHERE taken_by IS NULL" | get 0?.latest

        if $latest == null {
            break
        }

        if (date now) - ($latest | into datetime) > $wait {
            break
        }
    }

    open $db | query db "UPDATE collate_values SET taken_by = ? WHERE taken_by IS NULL" -p [$self_ident]
    let tasks = open $db | query db "SELECT value, inserted_at FROM collate_values WHERE taken_by = ?" -p [$self_ident]

    $tasks | update value { from json }
}

# Pack rectangles into an atlas using shelf packing.
# Input: table with `width` and `height` columns.
# Output: table with `x`, `y`, `width`, `height` columns (placed positions).
export def 'pack rects' [
    --target-width: int  # Preferred atlas width (auto if omitted)
]: [table<width: int, height: int> -> table<x: int, y: int, width: int, height: int>] {
    let rects = $in
    let count = ($rects | length)
    if $count == 0 { return [] }

    let total_area = ($rects | each { |r| $r.width * $r.height } | math sum)
    let target_w = ($target_width | default (($total_area | math sqrt | math ceil | into int) * 2))

    let sorted = ($rects | sort-by height --reverse)

    let state = ($sorted | reduce -f { placements: [], x: 0, y: 0, row_h: 0, max_w: 0 } { |rect, state|
        let start_new = ($state.x > 0 and ($state.x + $rect.width) > $target_w)
        let pos_x = if $start_new { 0 } else { $state.x }
        let pos_y = if $start_new { $state.y + $state.row_h } else { $state.y }
        let new_row_h = if $start_new { $rect.height } else { [$state.row_h, $rect.height] | math max }

        {
            placements: ($state.placements | append { x: $pos_x, y: $pos_y, width: $rect.width, height: $rect.height })
            x: ($pos_x + $rect.width)
            y: $pos_y
            row_h: $new_row_h
            max_w: ([$state.max_w, $pos_x + $rect.width] | math max)
        }
    })

    $state.placements
}

# Pack rectangles into an atlas using MaxRects Best Short Side Fit.
# Tends to use space more efficiently than the simple shelf packer.
export def 'pack rects2' [
]: [
    table<width: int, height: int> -> table<x: int, y: int, width: int, height: int>
] {
    let rects = $in
    let count = ($rects | length)
    if $count == 0 { return [] }

    let sorted = $rects
        | each { |r| $r | insert _p (($r.width + $r.height) * 2) }
        | sort-by _p --reverse
        | reject _p

    let total_area = ($sorted | each { |r| $r.width * $r.height } | math sum)
    let start_dim = (($total_area | math sqrt | math ceil | into int) | default 1)

    mut free = [{ x: 0, y: 0, width: $start_dim, height: $start_dim }]
    mut placements = []
    mut atlas_w = $start_dim
    mut atlas_h = $start_dim

    for rect in $sorted {
        let rw = $rect.width
        let rh = $rect.height

        loop {
            let best = $free
                | enumerate
                | each { |pair|
                    let f = $pair.item
                    if $f.width >= $rw and $f.height >= $rh {
                        let dw = $f.width - $rw
                        let dh = $f.height - $rh
                        {
                            index: $pair.index,
                            x: $f.x,
                            y: $f.y,
                            short: ([$dw, $dh] | math min),
                            long: ([$dw, $dh] | math max)
                        }
                    } else { null }
                }
                | where $it != null
                | sort-by short long
                | first

            if $best == null {
                # Expand atlas when no free rect fits
                let need_w = $rw > $atlas_w
                let need_h = $rh > $atlas_h

                if $need_w or (not $need_h and $atlas_w <= $atlas_h) {
                    $free ++= [{ x: $atlas_w, y: 0, width: $atlas_w, height: $atlas_h }]
                    $atlas_w *= 2
                } else {
                    $free ++= [{ x: 0, y: $atlas_h, width: $atlas_w, height: $atlas_h }]
                    $atlas_h *= 2
                }
            } else {
                $placements ++= [{ x: $best.x, y: $best.y, width: $rw, height: $rh }]

                let used = $free | get $best.index
                $free = ($free | enumerate | where { |pair| $pair.index != $best.index } | get item)

                # Split the used free rect into right and bottom pieces
                let right_w = $used.width - $rw
                let bottom_h = $used.height - $rh

                if $right_w > 0 {
                    $free ++= [{ x: ($used.x + $rw), y: $used.y, width: $right_w, height: $rh }]
                }
                if $bottom_h > 0 {
                    $free ++= [{ x: $used.x, y: ($used.y + $rh), width: $used.width, height: $bottom_h }]
                }

                # Prune: remove free rects fully contained within another
                let free_idx = $free | enumerate
                $free = ($free_idx | where { |pair|
                    let ri = $pair.index
                    let r = $pair.item
                    not ($free_idx | any { |opair|
                        ($opair.index != $ri
                            and $opair.item.x <= $r.x and $opair.item.y <= $r.y
                            and $opair.item.x + $opair.item.width >= $r.x + $r.width
                            and $opair.item.y + $opair.item.height >= $r.y + $r.height)
                    })
                } | get item)

                break
            }
        }
    }

    $placements
}
