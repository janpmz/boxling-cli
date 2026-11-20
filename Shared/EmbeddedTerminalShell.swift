import Foundation

/// The fixed shell setup shared by the desktop app and its access-approval service.
/// Exact argument comparison lets the service describe this as an interactive shell
/// without concealing arbitrary commands or changing authentication.
enum EmbeddedTerminalShell {
    // The script is an argument to Bash inside the box, never a command typed into
    // the terminal. No box name or directory is interpolated into executable code.
    private static let invocation = ["/bin/bash", "-c", #"exec /bin/bash --rcfile <(printf '%s\n' "$1") -i"#, "mybox-terminal"]
    static let arguments = invocation + [startupScript]
    // Older app instances can still open their exact, previously approved shell.
    static let legacyArguments = invocation + ["if [[ -r ~/.bashrc ]]; then source ~/.bashrc; fi\n" + promptSetup]
    static let startupScript = "if [[ -r ~/.bashrc ]]; then source ~/.bashrc; fi\n"
        + colorSetup + "\n" + promptSetup + "\n" + directorySetup

    // These defaults live only in the interactive session; no dotfiles or Git
    // configuration are written. Auto color keeps redirected output plain.
    static let colorSetup = #"""
    export COLORTERM=truecolor
    export CLICOLOR=1
    export LESS="${LESS:--R}"
    export LS_COLORS="${LS_COLORS:-rs=0:di=01;34:ln=01;36:ex=01;32:pi=33:so=35:bd=33:cd=33:or=01;31:mi=01;31:*.md=33:*.txt=37:*.json=33:*.yaml=33:*.yml=33:*.toml=33:*.js=36:*.jsx=36:*.ts=36:*.tsx=36:*.swift=36:*.py=36:*.rs=36:*.go=36:*.sh=32:*.png=35:*.jpg=35:*.jpeg=35:*.svg=35:*.webp=35:*.mp4=35:*.mp3=35:*.zip=31:*.gz=31:*.tar=31}"
    export GREP_COLORS="${GREP_COLORS:-ms=01;31:mc=01;31:fn=35:ln=33:bn=33:se=90}"
    if [[ $(type -t ls) == file || $(alias ls 2>/dev/null) == "alias ls='ls --color=auto'" ]]; then
        if command ls --color=auto --hyperlink=auto -d /dev/null >/dev/null 2>&1; then
            alias ls='ls --color=auto --hyperlink=auto'
        elif command ls --color=auto -d /dev/null >/dev/null 2>&1; then
            alias ls='ls --color=auto'
        fi
    fi
    if [[ $(type -t grep) == file ]]; then alias grep='grep --color=auto'; fi
    if [[ $(type -t diff) == file ]] && command diff --color=auto /dev/null /dev/null >/dev/null 2>&1; then
        alias diff='diff --color=auto'
    fi
    if [[ $(type -t git) == file ]]; then alias git='git -c color.ui=auto'; fi
    """#

    static let directorySetup = #"""
    __mybox_report_directory() {
        local __mybox_directory_status=$? LC_ALL=C value=$PWD index character code
        printf '\e]7;file://mybox'
        for ((index=0; index<${#value}; index++)); do
            character=${value:index:1}
            case "$character" in
                [/a-zA-Z0-9._~-]) printf '%s' "$character" ;;
                *) printf -v code '%d' "'$character"; printf '%%%02X' "$((code & 255))" ;;
            esac
        done
        printf '\a'
        return "$__mybox_directory_status"
    }
    if [[ $(declare -p PROMPT_COMMAND 2>/dev/null) == 'declare -a '* ]]; then
        PROMPT_COMMAND+=(__mybox_report_directory)
    else
        PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND$'\n'}__mybox_report_directory"
    fi
    __mybox_report_directory
    """#

    private static func segment(color: String, kind: String, encoded: String, text: String) -> String {
        #"\[\e]8;;mybox-prompt://\#(kind)/\#(encoded)\a\e[38;2;\#(color)m\]\#(text)\[\e]8;;\a\e[0m\]"#
    }

    private static let prompt = [
        segment(color: "166;218;149", kind: "copy", encoded: #"$(__mybox_prompt_hex "$__mybox_prompt_user")"#, text: #"${__mybox_prompt_user}"#),
        segment(color: "161;161;170", kind: "copy", encoded: "40", text: "@"),
        segment(color: "117;189;251", kind: "copy", encoded: #"$(__mybox_prompt_hex "$HOSTNAME")"#, text: #"$(__mybox_prompt_text "$HOSTNAME")"#),
        segment(color: "242;139;190", kind: "copy", encoded: "3a", text: ":"),
        segment(color: "198;160;246", kind: "path", encoded: #"$(__mybox_prompt_hex "$PWD")"#, text: #"$(__mybox_prompt_text "$PWD")"#),
        segment(color: "238;212;159", kind: "copy", encoded: #"$(__mybox_prompt_hex "$__mybox_prompt_symbol")"#, text: #"${__mybox_prompt_symbol}"#)
    ].joined() + " "

    static let promptSetup = #"""
    __mybox_prompt_user=$(id -un)
    __mybox_prompt_symbol='$'
    if (( EUID == 0 )); then __mybox_prompt_symbol='#'; fi
    __mybox_prompt_hex() {
        local LC_ALL=C value=$1 index
        for ((index=0; index<${#value}; index++)); do
            printf '%02x' "'${value:index:1}"
        done
    }
    __mybox_prompt_text() {
        local value=$1
        value=${value//[$'\001'-$'\037'$'\177']/?}
        printf '%s' "$value"
    }
    __mybox_prompt_set() {
        local __mybox_prompt_status=$?
        shopt -s promptvars
        PS1=\#(quote(prompt))
        return "$__mybox_prompt_status"
    }
    if [[ $(declare -p PROMPT_COMMAND 2>/dev/null) == 'declare -a '* ]]; then
        PROMPT_COMMAND+=(__mybox_prompt_set)
    else
        PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND$'\n'}__mybox_prompt_set"
    fi
    __mybox_prompt_set
    """#

    private static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
