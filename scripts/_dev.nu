use _str.nu *

def get-commands [] {
    # Quoting autocompletions because nushell doesn't automatically as needed
    scope commands | get name
}

export def get-param-default [
    command: string
    param: string
] {
    scope commands | where name == $command | get signatures.0.any | where parameter_name == $param | get 0.parameter_default
}

export def default-param [
    command: string
    param: string
] {
    default (get-param-default $command $param)
}

export def pin-procs [
    process: string
    procflag: int
] {
    powershell.exe ("foreach ($process in Get-Process " + $process + $") { $process.ProcessorAffinity=($procflag) }")
}

export def pin-procs-loop [
    process: string
    procflag: int
    --interval: duration = 1sec
] {
    loop {
        try { pin-procs $process $procflag }
        sleep $interval
    }
}

# Generate a wrapping command with copied flags as another
export def 'make wrapper' [
    command: string@get-commands
    --exported = true
] {
    let meta = scope commands | where name == $command | first

    let argslist = $meta.signatures | values | first | each { |arg|
        let name = $arg.parameter_name
        let opt = if $arg.is_optional and $arg.parameter_default == null { '?' }
        let ty = if $arg.syntax_shape != "any" { $": ($arg.syntax_shape)" }
        let comp = if $arg.custom_completion != "" { $"@($arg.custom_completion)" }
        let def = if $arg.parameter_default != null { $" = ($arg.parameter_default)" }
        let short = if $arg.short_flag != null { $"\(-($arg.short_flag)\)" }

        # If you want to vertically align comments, change how offset is calculated
        # You'll need the max of all the arg lines or something
        let with_comments = { |prefix|
            if $arg.description == "" { return $prefix }
            let offset = $prefix | str length

            let comments = $arg.description | lines | enumerate | each { |pair|
                let indent = if $pair.index == 0 {
                    ""
                } else {
                    str repeat " " $offset
                }

                $"($indent) # ($pair.item)\n"
            } | str join

            $"($prefix)($comments)"
        }

        match $arg.parameter_type {
            "positional" => (do $with_comments $"    ($name)($opt)($ty)($comp)($def)"),
            "named" => (do $with_comments $"    --($name)($short)($ty)($comp)($def)"),
            "switch" => (do $with_comments $"    --($name)($short)($def)"),
            "rest" => (do $with_comments $"    ...($name)($ty)($comp)"),
            _ => ""
        }
    } | str join "\n"

    $"(if $exported { 'export ' })def ($command)-wrapper [\n($argslist)] {\n    ($command) # TODO: Pass through flags\n}"
}

export def 'version update' [] {
    let root = mktemp --tmpdir --directory
    let moved_exe = mktemp --tmpdir --dry XXXXXX.oldnu.exe

    cargo install nu --root $root

    mv $nu.current-exe $moved_exe

    print $"moved ($nu.current-exe) to ($moved_exe)"

    mv $"($root)/bin/nu.exe" $nu.current-exe

    rm -r $root

    print $"moved new nu binary to ($nu.current-exe)"
}

export def 'version clean' [] {
    cd $nu.temp-dir

    rm ...(glob *.oldnu.exe) --verbose
}

export def diff-data-file [
    a
    b
    --nogit
] {
    let af = mktemp
    let bf = mktemp

    def read [ path ] { if ($path | describe) == 'string' and ($path | path exists) { open $path } else { $path } | table -e | ansi strip | str replace -ar '(?m)\s+$' '' }

    read $a | save -f $af
    read $b | save -f $bf

    let out = if $nogit {
        diff --color=always -U3 $bf $af | complete | get stdout
    } else {
        git diff --no-index --word-diff=color $bf $af | complete | get stdout
    }

    rm $af $bf

    $out
}
