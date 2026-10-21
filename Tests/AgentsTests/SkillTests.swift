import Foundation
import Testing
@testable import Agents

/// A skill as this app writes it, naming `command`.
func skill(_ command: String, body: String = "# Apple Reminders\n") -> String {
    "---\nname: apple-reminders\ndescription: Reminders\nmetadata:\n  \(SkillTarget.marker)\n  command: \"\(command)\"\n---\n\n\(body)"
}

@Suite struct SkillTests {
    @Test func folders() throws {
        let box = try Sandbox()
        let home = box.home.path
        let expected: [SkillTarget: String] = [
            .claude: ".claude/skills", .agents: ".agents/skills", .gemini: ".agents/skills", .grok: ".grok/skills",
            .antigravity: ".gemini/config/skills", .antigravityCLI: ".gemini/antigravity-cli/skills",
        ]
        for target in SkillTarget.allCases {
            #expect(target.file(home: box.home).path == "\(home)/\(expected[target]!)/apple-reminders/SKILL.md", "\(target)")
            let inProject = target == .claude ? ".claude/skills" : ".agents/skills"
            #expect(target.file(project: URL(fileURLWithPath: "/p"), home: box.home).path == "/p/\(inProject)/apple-reminders/SKILL.md", "\(target)")
        }
    }

    @Test func judgesTheSkillThere() throws {
        let box = try Sandbox()
        let text = skill(box.command)
        #expect(SkillTarget.agents.registration(of: text, home: box.home) == .missing)
        let url = try SkillTarget.agents.install(text, home: box.home)
        #expect(try String(contentsOf: url, encoding: .utf8) == text)
        #expect(SkillTarget.agents.registration(of: text, home: box.home) == .current)
        // Gemini CLI reads the same folder.
        #expect(SkillTarget.gemini.registration(of: text, home: box.home) == .current)
        // What a newer version would write.
        #expect(SkillTarget.agents.registration(of: skill(box.command, body: "# Newer\n"), home: box.home) == .different(command: box.command))
        // Another copy's skill, and one whose copy is gone; both are this app's to replace.
        try SkillTarget.agents.install(skill("/bin/sh"), home: box.home)
        #expect(SkillTarget.agents.registration(of: text, home: box.home) == .different(command: "/bin/sh"))
        try SkillTarget.agents.install(skill("/nowhere/apple-reminders-mcp"), home: box.home)
        #expect(SkillTarget.agents.registration(of: text, home: box.home) == .broken(command: "/nowhere/apple-reminders-mcp"))
        // Rewritten in place, with no backups beside it.
        try SkillTarget.agents.install(text, home: box.home)
        #expect(SkillTarget.agents.registration(of: text, home: box.home) == .current)
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == ["SKILL.md"])
    }

    @Test func readsTheCommandBackWhateverItHolds() {
        #expect(SkillTarget.command(in: skill("/Users/a b/Apps/AppleRemindersMCP")) == "/Users/a b/Apps/AppleRemindersMCP")
        #expect(SkillTarget.command(in: "---\nmetadata:\n  command: /plain/path\n---\n") == "/plain/path")
        #expect(SkillTarget.command(in: "no frontmatter\ncommand: /x\n") == nil)
    }

    @Test func leavesSomeoneElsesSkillAlone() throws {
        let box = try Sandbox()
        let url = SkillTarget.claude.file(home: box.home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let theirs = "---\nname: apple-reminders\ndescription: Mine\n---\n\nHand-written; mentions generated-by: apple-reminders-mcp below the frontmatter.\n"
        try theirs.write(to: url, atomically: true, encoding: .utf8)
        guard case .notEditable = SkillTarget.claude.registration(of: skill(box.command), home: box.home) else {
            Issue.record("expected notEditable")
            return
        }
        #expect(throws: ConfigError.self) { try SkillTarget.claude.install(skill(box.command), home: box.home) }
        #expect(try String(contentsOf: url, encoding: .utf8) == theirs)
    }

    @Test func projectFolders() throws {
        let box = try Sandbox()
        let project = box.home.appendingPathComponent("project", isDirectory: true)
        #expect(throws: ConfigError.self) { try SkillTarget.claude.install(skill(box.command), project: project, home: box.home) }
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let url = try SkillTarget.claude.install(skill(box.command), project: project, home: box.home)
        #expect(url.path == project.path + "/.claude/skills/apple-reminders/SKILL.md")
        #expect(SkillTarget.claude.registration(of: skill(box.command), project: project, home: box.home) == .current)
        #expect(SkillTarget.claude.registration(of: skill(box.command), home: box.home) == .missing)
    }

    @Test func followsALinkedSkillFolder() throws {
        // ~/.claude/skills/apple-reminders linked to ~/.agents/skills/apple-reminders, as people share skills.
        let box = try Sandbox()
        let shared = SkillTarget.agents.file(home: box.home).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let link = SkillTarget.claude.file(home: box.home).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: shared)
        try SkillTarget.claude.install(skill(box.command), home: box.home)
        #expect(SkillTarget.agents.registration(of: skill(box.command), home: box.home) == .current)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == shared.path)
    }

    @Test func agentsThatRunCommandsHaveSkills() throws {
        let box = try Sandbox()
        #expect(Agent.all.filter { $0.skills == nil }.map(\.id) == ["grok-bot", "gemini-app"])
        // The apps share their command-line tools' folders, so set-up writes those files once.
        let files = Dictionary(grouping: Agent.all.filter { $0.skills != nil }) { $0.skills!.file(home: box.home).path }
        #expect(files.count == 5)
        #expect(Set(files[SkillTarget.agents.file(home: box.home).path]!.map(\.id)) == ["codex", "chatgpt", "opencode", "opencode-desktop", "gemini"])
    }
}
