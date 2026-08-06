use std

# Insert a table of rows into a sqlite handle efficiently
export def 'sqlite batchsert' [
    table_name: string,
    data,
    --group-size: int = 128
] {
    let db = $in

    let columns = $data | columns

    let coldec = $columns | each { |col| $"'($col)'" } | str join ","
    let prefix = $"INSERT INTO '($table_name)' \(($coldec)\) VALUES "

    let batch_values = 0..<$group_size
        | each { |i| '(' + ($columns | each { '?' } | str join ',') + ')' }
        | str join ","
    let batch_stmt = $prefix + $batch_values + ";"

    $data | window $group_size --stride $group_size | each { |g|
        let params = $g | each { |row| $row | values } | flatten

        $db | query db $batch_stmt -p $params | ignore
    }

    let remainder = ($data | length) mod $group_size
    if $remainder > 0 {
        let remainder_values = 0..<$remainder
            | each { |i| '(' + ($columns | each { '?' } | str join ',') + ')' }
            | str join ","
        let remainder_stmt = $prefix + $remainder_values + ";"

        let params = ($data | last $remainder) | each { |row| $row | values } | flatten
        $db | query db $remainder_stmt -p $params | ignore
    }
}

# Run this to prepare the arguments for `sqlite batched`
#
# ```
# sqlite data.db (sqlite batched-prepare data_table)
# ```
export def 'sqlite batched-prepare' [
    table_name: string
    columns: list # The table columns in the order consumed
    --replace
    --group-size: int = 128
] {
    let coldec = $columns | each { |col| $"'($col)'" } | str join ","
    let prefix = $"(if $replace { 'REPLACE' } else { 'INSERT' }) INTO '($table_name)' \(($coldec)\) VALUES "
    let batch_values = 0..<$group_size
        | each { |i| '(' + ($columns | each { '?' } | str join ',') + ')' }
        | str join ","
    let batch_stmt = $prefix + $batch_values + ";"

    {
        group_size: $group_size,
        batch_stmt: $batch_stmt,
        prefix: $prefix,
        columns: $columns
    }
}

export def 'sqlite batched' [
    db_handle
    prepared
] {
    chunks $prepared.group_size | each { |g|
        let params = $g | each { |row|
            $prepared.columns | each -k { |col| $row | get $col | default '' }
        } | flatten

        let batch_stmt = if ($g | length) == $prepared.group_size {
            $prepared.batch_stmt
        } else {
            let remainder_values = 0..<($g | length)
                | each { |i| '(' + ($prepared.columns | each { '?' } | str join ',') + ')' }
                | str join ","
            let remainder_stmt = $prepared.prefix + $remainder_values + ";"

            $remainder_stmt
        }

        $db_handle | query db $batch_stmt -p $params | ignore
    }
}

export def 'sqlite init' [
    path: oneof<list, path>
    init?: oneof<list, string>
] {
    let maybe_handle = $in
    let input_is_db = ($maybe_handle | describe -d | get detailed_type?) == 'SQLiteDatabase'
    let maybe_handle = if $input_is_db {
        $maybe_handle
    } else {
        null
    }

    let inits = if $input_is_db {
        std assert equal (type-of $path) list
        std assert equal $init null

        # $path must hold a list of statements now
        $path
    } else {
        $init
    }

    if not $input_is_db {
        let exists = $path | path exists

        if not $exists {
            { x: 'y' } | into sqlite $path -t _init_sentinel
        }
    }

    if $inits != null {
        if (type-is $inits "list") {
            let handle = $maybe_handle | default { open $path }
            $inits | each { |sql| $handle | query db $sql }
        } else {
            open $path | query db $inits
        }
    }

    null
}
