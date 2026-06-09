export def 'history find' [
    ...terms
    --regex
] {
    let finder = if $regex {
        { |row| $terms | all { |term| $row.command =~ $term } }
    } else {
        { |row| $terms | all { |term| $row.command | str contains -i $term } }
    }

    history | where $finder | reject cwd duration exit_status
}

export alias base-history = history
export def 'history' [
    last?: int
    # --clear(-c) # Not exposed, just in case
    --long(-l) # Will break the `rename`
    --find(-f): string
    --cwd
    --noprint
] {
    # Filter cwd by default for space, table width collapsing is otherwise annoying
    let filter_cwd = if $cwd { [] } else { ['cwd'] }

    # We can buffer our rows because `base-history` does **not** stream (afaict)
    # timeit { history | first } timeit { history | last }

    let rows = if $find != null {
        base-history --long=$long
            | where command =~ $"\(?i)($find)"
            | rename timestamp command cwd duration code
            | move duration --before command
            | reject ...$filter_cwd
            | (if $last != null { last $last } else { $in })
            | update command { nu-highlight | str replace -a "\e[1;41;39m" (ansi purple) }
    } else {
        base-history --long=$long
            | rename timestamp command cwd duration code
            | move duration --before command
            | reject ...$filter_cwd
            | (if $last != null { last $last } else { $in })
    }

    if $noprint {
        $rows
    } else {
        $rows | table --index false --theme light
    }
}

export def sanitize-nu-clipboard [] {
    bp | lines | each { |line| $line | str replace -a "\t" "    " } | str join "\r\n" | bp
}
