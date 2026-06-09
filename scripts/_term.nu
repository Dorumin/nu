use _str.nu *

# Clear terminal but without losing scrollback
export def 'term clear-spaced' [] {
    0..(term size | get rows) | each { print "" }
    clear -k
}

# Move the cursor in the terminal in absolute units
export def 'term move-cursor' [
    x: int # 0-indexed column to move the cursor to. Max to (term size).columns - 1
    y: int # 0-indexed row to move the cursor to. Max to (term size).rows - 1
] {
    print -n $"\e[($y + 1);($x + 1)H";
}

# Get the current position of the cursor
export def 'term get-cursor-pos' [
    --restore = true
]: [nothing -> record<x: int, y: int>] {
    print "\e[6n"

    let res = input -s -u R
        | parse -r '^\[(?<y>\d+);(?<x>\d+)' # Input does not include delimiting "R"
        | first
        | update x { ($in | into int) - 1 }
        | update y { ($in | into int) - 1 }

    # This seems redundant, but we have to do it to preserve the position.
    # Above input, despite being silent, moves the cursor down.
    if $restore {
        term move-cursor $res.x $res.y
    }

    $res
}

# Get the current position of the cursor
export def 'term retain-position' [
    closure: closure
] {
    let pos = term get-cursor-pos

    do $closure

    term move-cursor $pos.x $pos.y
}

# Print text at a specific position without permanently moving the cursor
export def 'term print-at' [
    x: int
    y: int
    text: string
    --restore (-r) # Restore cursor after printing
    --clear-line (-c) # Clear rest of line
] {
    let original = if $restore {
        term get-cursor-pos
    }

    term move-cursor $x $y
    print -n $text

    if $clear_line {
        term clear-rest-of-line
    }

    if $restore {
        term move-cursor $original.x $original.y
    }
}

export def 'term clear-rest-of-line' [] {
    print -n "\e[K"
}

# Clear entire current line
export def 'term clear-line' [] {
    print -n "\e[2K"
}

# Clear from cursor to end of screen
export def 'term clear-rest-of-screen' [] {
    print -n "\e[J"
}
