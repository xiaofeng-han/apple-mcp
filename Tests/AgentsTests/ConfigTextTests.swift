import Foundation
import Testing
@testable import Agents

let entry: ConfigValue = .object([("command", .string("/opt/homebrew/bin/apple-reminders-mcp")), ("args", .array([.string("--stdio")]))])

@Suite struct JSONTextTests {
    func set(_ text: String, _ path: [String] = ["mcpServers", "apple-reminders"], to value: ConfigValue = entry) throws -> String {
        var document = JSONText(text)
        try document.set(path, to: value)
        return document.text
    }

    @Test func emptyFileGetsAnObject() throws {
        #expect(try set("") == """
            {
              "mcpServers": {
                "apple-reminders": {
                  "command": "/opt/homebrew/bin/apple-reminders-mcp",
                  "args": ["--stdio"]
                }
              }
            }

            """)
    }

    @Test func addsAfterOtherKeysKeepingTheirOrder() throws {
        let before = """
            {
                "zeta": 1,
                "alpha": {"nested": [1, 2]}
            }
            """
        #expect(try set(before) == """
            {
                "zeta": 1,
                "alpha": {"nested": [1, 2]},
                "mcpServers": {
                    "apple-reminders": {
                        "command": "/opt/homebrew/bin/apple-reminders-mcp",
                        "args": ["--stdio"]
                    }
                }
            }
            """)
    }

    @Test func addsToAnExistingObjectAndKeepsOtherServers() throws {
        let before = """
            {
              "mcpServers": {
                "other": { "command": "x" }
              },
              "preferences": {}
            }
            """
        #expect(try set(before) == """
            {
              "mcpServers": {
                "other": { "command": "x" },
                "apple-reminders": {
                  "command": "/opt/homebrew/bin/apple-reminders-mcp",
                  "args": ["--stdio"]
                }
              },
              "preferences": {}
            }
            """)
    }

    @Test func fillsAnEmptyObject() throws {
        #expect(try set("{\n  \"mcpServers\": {}\n}\n") == """
            {
              "mcpServers": {
                "apple-reminders": {
                  "command": "/opt/homebrew/bin/apple-reminders-mcp",
                  "args": ["--stdio"]
                }
              }
            }

            """)
    }

    @Test func replacesAnExistingEntryOnly() throws {
        let before = """
            {
              // servers
              "mcpServers": {
                "apple-reminders": {"command": "/old/path", "args": []}, // old
                "b": {"command": "y"},
              },
            }
            """
        #expect(try set(before) == """
            {
              // servers
              "mcpServers": {
                "apple-reminders": {
                  "command": "/opt/homebrew/bin/apple-reminders-mcp",
                  "args": ["--stdio"]
                }, // old
                "b": {"command": "y"},
              },
            }
            """)
    }

    @Test func keepsCommentsAndTrailingCommas() throws {
        let before = """
            {
              "$schema": "https://opencode.ai/config.json", // schema
              /* block */
              "mcp": {
                "a": {"type": "local"}, // a
              }
            }
            """
        let after = try set(before, ["mcp", "apple-reminders"], to: .object([("type", .string("local")), ("command", .array([.string("/x"), .string("--stdio")]))]))
        #expect(after == """
            {
              "$schema": "https://opencode.ai/config.json", // schema
              /* block */
              "mcp": {
                "a": {"type": "local"}, // a
                "apple-reminders": {
                  "type": "local",
                  "command": ["/x", "--stdio"]
                },
              }
            }
            """)
    }

    @Test func commentAfterTheLastMemberStaysOnItsLine() throws {
        let before = "{\n  \"a\": 1 // one\n}\n"
        #expect(try set(before, ["b"], to: .bool(true)) == "{\n  \"a\": 1, // one\n  \"b\": true\n}\n")
    }

    @Test func oneLineObjectsStayOnOneLine() throws {
        #expect(try set("{\"a\": 1}", ["b"], to: .string("x")) == "{\"a\": 1, \"b\": \"x\"}")
    }

    @Test func keepsCRLFLineEndings() throws {
        #expect(try set("{\r\n  \"a\": 1\r\n}\r\n", ["b"], to: .bool(false)) == "{\r\n  \"a\": 1,\r\n  \"b\": false\r\n}\r\n")
    }

    @Test func escapesAndUnicode() throws {
        let after = try set("{}", ["mcpServers", "apple-reminders"], to: .object([("command", .string("/Users/张三/a \"b\"/c"))]))
        let read = try JSONText(after).value(at: ["mcpServers", "apple-reminders", "command"]) as? String
        #expect(read == "/Users/张三/a \"b\"/c")
    }

    @Test func refusesWhatIsNotAnObject() {
        #expect(throws: ConfigError.self) { try set("[]") }
        #expect(throws: ConfigError.self) { try set("{\"mcpServers\": [] }") }
        #expect(throws: ConfigError.self) { try set("{\"mcpServers\": {") }
    }

    @Test func readsAnEscapedNull() throws {
        #expect(try JSONText("{\"a\": \"x\\u0000y\"}").value(at: ["a"]) as? String == "x\u{0}y")
    }

    @Test func readsJSONC() throws {
        let document = JSONText("{ // c\n \"mcp\": { \"x\": { \"enabled\": true, }, }, }")
        #expect(try document.value(at: ["mcp", "x", "enabled"]) as? Bool == true)
        #expect(try document.value(at: ["mcp", "y"]) == nil)
    }
}

@Suite struct TOMLTextTests {
    let table = ["mcp_servers", "apple-reminders"]
    let pairs: [(String, ConfigValue)] = [("command", .string("/opt/homebrew/bin/apple-reminders-mcp")), ("args", .array([.string("--stdio")]))]

    func set(_ text: String, _ pairs: [(String, ConfigValue)]? = nil) throws -> String {
        var document = try TOMLText(text)
        try document.set(pairs ?? self.pairs, in: table)
        return document.text
    }

    @Test func appendsATable() throws {
        let before = """
            model = "gpt-5"

            [mcp_servers.other]
            command = "x"

            [mcp_servers.other.env]
            A = "1"
            """
        #expect(try set(before) == before + """


            [mcp_servers.apple-reminders]
            command = "/opt/homebrew/bin/apple-reminders-mcp"
            args = ["--stdio"]

            """)
        #expect(try set("") == "[mcp_servers.apple-reminders]\ncommand = \"/opt/homebrew/bin/apple-reminders-mcp\"\nargs = [\"--stdio\"]\n")
    }

    @Test func replacesValuesInPlace() throws {
        let before = """
            [mcp_servers.apple-reminders]   # reminders
            command = '/old/path' # old
            args = [
              "--stdio", # comment ]
              "x",
            ]
            startup_timeout_sec = 20

            [mcp_servers.apple-reminders.env]
            A = "1"

            [tui]
            theme = "dark"
            """
        #expect(try set(before, pairs + [("enabled", .bool(true))]) == """
            [mcp_servers.apple-reminders]   # reminders
            enabled = true
            command = "/opt/homebrew/bin/apple-reminders-mcp" # old
            args = ["--stdio"]
            startup_timeout_sec = 20

            [mcp_servers.apple-reminders.env]
            A = "1"

            [tui]
            theme = "dark"
            """)
    }

    @Test func quotedHeadersAndKeys() throws {
        let before = "[mcp_servers.\"apple-reminders\"]\n\"command\" = \"/a\"\nenabled = false\n"
        let after = try set(before, pairs + [("enabled", .bool(true))])
        #expect(after == "[mcp_servers.\"apple-reminders\"]\nargs = [\"--stdio\"]\n\"command\" = \"/opt/homebrew/bin/apple-reminders-mcp\"\nenabled = true\n")
    }

    @Test func readsValues() throws {
        let document = try TOMLText("""
            [mcp_servers.apple-reminders]
            command = "/a/\\u00e9\\"b"
            args = ['--stdio', \"\"\"
            x\"\"\"]
            enabled = true
            when = 1979-05-27 07:32:00Z
            n = 3
            """)
        #expect(document.value("command", in: table) as? String == "/a/é\"b")
        #expect(document.value("args", in: table) as? [String] == ["--stdio", "x"])
        #expect(document.value("enabled", in: table) as? Bool == true)
        #expect(document.value("n", in: table) == nil)
        #expect(document.value("command", in: ["mcp_servers", "other"]) == nil)
    }

    @Test func refusesInlineDefinitions() throws {
        #expect(throws: ConfigError.self) { try set("[mcp_servers]\napple-reminders = { command = \"/a\" }\n") }
        #expect(throws: ConfigError.self) { try set("mcp_servers.apple-reminders.command = \"/a\"\n") }
        #expect(throws: ConfigError.self) { try set("mcp_servers = {}\n") }
        // Other servers written inline are fine.
        #expect(try set("[mcp_servers]\nother = { command = \"/a\" }\n").contains("[mcp_servers.apple-reminders]"))
    }

    @Test func refusesInvalidTOML() {
        #expect(throws: ConfigError.self) { try TOMLText("[a\nb = 1") }
        #expect(throws: ConfigError.self) { try TOMLText("a = \"unclosed\n") }
        #expect(throws: ConfigError.self) { try TOMLText("a = [1, 2") }
    }

    @Test func addsAfterAHeaderCommentInCRLF() throws {
        let after = try set("[mcp_servers.apple-reminders] # reminders\r\ncommand = \"/old\"\r\n")
        #expect(after == "[mcp_servers.apple-reminders] # reminders\r\nargs = [\"--stdio\"]\r\ncommand = \"/opt/homebrew/bin/apple-reminders-mcp\"\r\n")
    }

    @Test func keepsCRLF() throws {
        #expect(try set("a = 1\r\n") == "a = 1\r\n\r\n[mcp_servers.apple-reminders]\r\ncommand = \"/opt/homebrew/bin/apple-reminders-mcp\"\r\nargs = [\"--stdio\"]\r\n")
    }
}
