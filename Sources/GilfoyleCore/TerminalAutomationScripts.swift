import Foundation

/// Focus and delivery are deliberately separate capabilities. Reply scripts
/// never request activation, window selection, or tab selection. Terminal.app
/// can still foreground itself as a side effect of `do script`; the app layer
/// restores the previously active application after background delivery.
public enum TerminalAutomationScripts {
    public static let terminalSend = """
    on run argv
        set targetTTY to item 1 of argv
        set promptText to item 2 of argv
        tell application "Terminal"
            repeat with terminalWindow in windows
                repeat with terminalTab in tabs of terminalWindow
                    if tty of terminalTab is targetTTY then
                        -- `do script` supplies one Return. Interactive TUIs
                        -- can consume it to finish a paste, so send one second
                        -- empty native command without explicitly selecting
                        -- or activating the window.
                        do script promptText in terminalTab
                        delay 0.35
                        do script "" in terminalTab
                        return "ok"
                    end if
                end repeat
            end repeat
        end tell
        return "not-found"
    end run
    """

    public static let terminalSubmit = """
    on run argv
        set targetTTY to item 1 of argv
        tell application "Terminal"
            repeat with terminalWindow in windows
                repeat with terminalTab in tabs of terminalWindow
                    if tty of terminalTab is targetTTY then
                        do script "" in terminalTab
                        return "ok"
                    end if
                end repeat
            end repeat
        end tell
        return "not-found"
    end run
    """

    /// Terminal's scripting dictionary can close a window but not an
    /// individual tab. A one-tab window is therefore closed directly; for a
    /// multi-tab window we exit only the shell attached to the exact TTY. The
    /// default Terminal profile then removes that cleanly exited tab without
    /// selecting it or disturbing neighbouring tabs.
    public static let terminalClose = """
    on run argv
        set targetTTY to item 1 of argv
        tell application "Terminal"
            repeat with terminalWindow in windows
                repeat with terminalTab in tabs of terminalWindow
                    if tty of terminalTab is targetTTY then
                        if (count of tabs of terminalWindow) is 1 then
                            close terminalWindow
                        else
                            do script "exit" in terminalTab
                        end if
                        return "ok"
                    end if
                end repeat
            end repeat
        end tell
        return "not-found"
    end run
    """

    public static let terminalFocus = """
    on run argv
        set targetTTY to item 1 of argv
        tell application "Terminal"
            repeat with terminalWindow in windows
                repeat with terminalTab in tabs of terminalWindow
                    if tty of terminalTab is targetTTY then
                        set selected of terminalTab to true
                        set index of terminalWindow to 1
                        activate
                        return "ok"
                    end if
                end repeat
            end repeat
        end tell
        return "not-found"
    end run
    """

    public static let iTermSubmit = """
    on run argv
        set targetIdentifier to item 1 of argv
        set targetTTY to item 2 of argv
        if targetIdentifier contains ":" then
            set AppleScript's text item delimiters to ":"
            set identifierParts to text items of targetIdentifier
            set targetIdentifier to last item of identifierParts
            set AppleScript's text item delimiters to ""
        end if
        tell application "iTerm2"
            repeat with terminalWindow in windows
                repeat with terminalTab in tabs of terminalWindow
                    repeat with terminalSession in sessions of terminalTab
                        set sessionIdentifier to unique ID of terminalSession
                        set sessionTTY to tty of terminalSession
                        if (targetIdentifier is not "" and sessionIdentifier is targetIdentifier) or (targetTTY is not "" and sessionTTY is targetTTY) then
                            write terminalSession text "" newline yes
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "not-found"
    end run
    """

    /// iTerm exposes sessions rather than Terminal-style tab closing. Sending
    /// `exit` to the exact unique ID/TTY closes only that cleanly returned
    /// shell according to the user's profile, without selecting the session.
    public static let iTermClose = """
    on run argv
        set targetIdentifier to item 1 of argv
        set targetTTY to item 2 of argv
        if targetIdentifier contains ":" then
            set AppleScript's text item delimiters to ":"
            set identifierParts to text items of targetIdentifier
            set targetIdentifier to last item of identifierParts
            set AppleScript's text item delimiters to ""
        end if
        tell application "iTerm2"
            repeat with terminalWindow in windows
                repeat with terminalTab in tabs of terminalWindow
                    repeat with terminalSession in sessions of terminalTab
                        set sessionIdentifier to unique ID of terminalSession
                        set sessionTTY to tty of terminalSession
                        if (targetIdentifier is not "" and sessionIdentifier is targetIdentifier) or (targetTTY is not "" and sessionTTY is targetTTY) then
                            write terminalSession text "exit" newline yes
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "not-found"
    end run
    """

    public static let iTermSend = """
    on run argv
        set targetIdentifier to item 1 of argv
        set targetTTY to item 2 of argv
        set promptText to item 3 of argv
        if targetIdentifier contains ":" then
            set AppleScript's text item delimiters to ":"
            set identifierParts to text items of targetIdentifier
            set targetIdentifier to last item of identifierParts
            set AppleScript's text item delimiters to ""
        end if
        tell application "iTerm2"
            repeat with terminalWindow in windows
                repeat with terminalTab in tabs of terminalWindow
                    repeat with terminalSession in sessions of terminalTab
                        set sessionIdentifier to unique ID of terminalSession
                        set sessionTTY to tty of terminalSession
                        if (targetIdentifier is not "" and sessionIdentifier is targetIdentifier) or (targetTTY is not "" and sessionTTY is targetTTY) then
                            write terminalSession text promptText newline yes
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "not-found"
    end run
    """

    public static let iTermFocus = """
    on run argv
        set targetIdentifier to item 1 of argv
        set targetTTY to item 2 of argv
        if targetIdentifier contains ":" then
            set AppleScript's text item delimiters to ":"
            set identifierParts to text items of targetIdentifier
            set targetIdentifier to last item of identifierParts
            set AppleScript's text item delimiters to ""
        end if
        tell application "iTerm2"
            repeat with terminalWindow in windows
                repeat with terminalTab in tabs of terminalWindow
                    repeat with terminalSession in sessions of terminalTab
                        set sessionIdentifier to unique ID of terminalSession
                        set sessionTTY to tty of terminalSession
                        if (targetIdentifier is not "" and sessionIdentifier is targetIdentifier) or (targetTTY is not "" and sessionTTY is targetTTY) then
                            select terminalSession
                            select terminalTab
                            select terminalWindow
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "not-found"
    end run
    """
}
