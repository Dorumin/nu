source aliases.nu

use scripts/mod.nu *

# Default to ~/Code
let normal_pwd = ($env.PWD | str downcase)
let redirect_pwds = [
    ($env.windir? | default '' | path join System32 | str downcase),
    ($env.USERPROFILE? | default $env.HOME | path join .cargo bin | str downcase)
]

let next_pwd = if $normal_pwd in $redirect_pwds {
	'~/Code'
} else {
	'.'
}

cd $next_pwd

$env.PROMPT_MULTILINE_INDICATOR = { || "" }
$env.PROMPT_COMMAND_RIGHT = { || "" }

$env.config.show_banner = false
$env.config.rm.always_trash = true

$env.config.history.file_format = 'sqlite'

$env.config.ls.clickable_links = false

$env.config.filesize.unit = 'binary'

# Tables
$env.config.table.index_mode = 'always'

# Cursor
$env.config.cursor_shape.emacs = 'line'

# Hotkeys
$env.config.keybindings ++= [
    {
        name: new_line_shift # Shift+enter for newline without repl prompt
        modifier: shift
        keycode: enter
        mode: emacs
        event: { edit: insertnewline }
    },
    {
        name: new_line_alt # Alt+enter works on vsc terminal without fiddling with skip shell shortcuts
        modifier: alt
        keycode: enter
        mode: emacs
        event: { edit: insertnewline }
    },
    {
        name: clear_screen_better # This behaves better with clearing history
        modifier: control
        keycode: char_l
        mode: emacs
        event: {
            send: executehostcommand,
            cmd: $"clear -k"
        }
    },
    {
        name: reload_config
        modifier: none
        keycode: f6
        mode: emacs
        event: {
          send: executehostcommand,
          cmd: $"source '($nu.env-path)';source '($nu.config-path)'"
        }
    },
    {
        # Restart nu
        name: re_exec_nu
        modifier: none
        keycode: f5
        mode: [emacs vi_normal vi_insert]
        event: [
            {
                send: executehostcommand
                cmd: "print -n '\r'; exec $nu.current-exe"
            }
        ]
    }
    {
        name: reload_config
        modifier: none
        keycode: f3
        mode: emacs
        event: [
            {edit: MoveToEnd}
            {send: ExecuteHostCommand, cmd: "
                print a
                sleep 1sec
                print b
            "}
            {edit: InsertChar, value: '⌛'}
        ]
    }
]

## Remove superseded hotkeys
$env.config.keybindings = ($env.config.keybindings | where $it.name != "clear_screen")
