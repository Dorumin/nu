# assoc but as a table
export def assoc [] {
    ^assoc | parse "{ext}={association}" | str trim
}

def ftype_complete [] {
    assoc | get association | sort
}

# Sets the user wide file type association
export def 'set ftype' [
    ftype: string@"ftype_complete",
    command: string
] {
    ftype $"($ftype)=($command) %1"
}
