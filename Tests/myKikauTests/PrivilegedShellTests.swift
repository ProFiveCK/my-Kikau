import Foundation
import Testing
@testable import Core

struct PrivilegedShellTests {
    @Test("makeScript wraps the command in an administrator-privileges AppleScript")
    func wrapsCommand() {
        let script = PrivilegedShell.makeScript(for: "/usr/sbin/ipconfig set en0 DHCP")
        #expect(script == "do shell script \"/usr/sbin/ipconfig set en0 DHCP\" with administrator privileges")
    }

    @Test("makeScript escapes quotes and backslashes for the AppleScript string literal")
    func escapesSpecials() {
        let script = PrivilegedShell.makeScript(for: #"echo "hi" \ there"#)
        // " -> \"  and  \ -> \\
        #expect(script == #"do shell script "echo \"hi\" \\ there" with administrator privileges"#)
    }
}
