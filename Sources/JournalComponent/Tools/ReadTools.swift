import Foundation
import Wire

func readTools(_ store: JournalStore) -> [Tool] {
    [
        Tool("overview", title: "Journal overview",
             summary: """
                 The journals (with their colors, icons and how many entries each holds), how many entries there \
                 are in all, bookmarked and in Recently Deleted, and the insights Journal shows: days journaled and \
                 daily and weekly streaks.
                 """,
             input: Schema.object([:]), effect: .reads) { _ in
            try await withJournal(store) {
                let entries = try store.entryObjects(deleted: nil).map(store.info)
                let live = entries.filter { $0.deleted == nil }
                let journals = try store.journalObjects().filter { !$0.isDefaultJournal }.map(store.info).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                let insights = Insights(dates: live.map(\.date))
                var result: [String: JSON] = [
                    "journals": .array(journals.map { journal in Output.journal(journal, entries: live.filter { $0.journals.contains(journal.id) }.count) }),
                    "all_entries": .int(live.count),
                    "bookmarked": .int(live.filter(\.bookmarked).count),
                    "recently_deleted": .int(entries.count - live.count),
                    "insights": [
                        "days_journaled": .int(insights.daysJournaled), "days_this_year": .int(insights.daysThisYear),
                        "entries_this_year": .int(insights.entriesThisYear),
                        "daily_streak": .int(insights.currentDailyStreak), "longest_daily_streak": .int(insights.longestDailyStreak),
                        "weekly_streak": .int(insights.currentWeeklyStreak), "longest_weekly_streak": .int(insights.longestWeeklyStreak),
                    ],
                    "now": .string(Output.stamp(Date())), "time_zone": .string(TimeZone.current.identifier),
                ]
                if let first = insights.first { result["first_entry"] = .string(Output.day(first)) }
                if let last = insights.last { result["last_entry"] = .string(Output.day(last)) }
                if !store.syncsWithICloud() { result["icloud"] = "off: Journal on this Mac does not sync with iCloud" }
                return ToolAnswer(JSON.object(result).text)
            }
        },

        Tool("find_entries", title: "Find journal entries",
             summary: """
                 Finds entries, newest first: by words (in the title, the text, the writing prompt, and the places, \
                 people, songs, transcripts and handwriting of attachments), journal, bookmark, date and kind of \
                 attachment. Each comes with its id and version, a snippet and its attachments by kind. after is \
                 inclusive, before exclusive.
                 """,
             input: Schema.object([
                 "query": Schema.text("Words that must all appear"),
                 "journal": Schema.text("Only entries in this journal (name or id)"),
                 "bookmarked": Schema.flag("Only bookmarked entries"),
                 "after": Schema.text("2026-10-21: entries dated that day or later"),
                 "before": Schema.text("2026-10-21: entries dated before that day"),
                 "attachments": Schema.list(of: ["type": "string", "enum": .array((AssetDetails.kinds.map(\.name) + ["any", "none"]).map { .string($0) })],
                                            "Only entries with an attachment of one of these kinds; any, or none"),
                 "deleted": Schema.flag("Look in Recently Deleted instead"),
                 "sort": Schema.choice(["newest", "oldest", "edited"], "Default newest (by the entry's date); edited: most recently changed first"),
                 "limit": Schema.whole("Default 50, at most 500"),
                 "offset": Schema.whole("Skip this many, for the next page"),
             ]), effect: .reads) { fields in
            let input = Input(fields)
            let query = try input.text("query"), journalName = try input.text("journal")
            let bookmarked = try input.flag("bookmarked") ?? false, deleted = try input.flag("deleted") ?? false
            let after = try input.day("after"), before = try input.day("before")
            let kinds = try (input.texts("attachments") ?? []).map { kind in
                guard AssetDetails.kinds.contains(where: { $0.name == kind }) || kind == "any" || kind == "none" else {
                    throw BadInput("attachments takes " + (AssetDetails.kinds.map(\.name) + ["any", "none"]).joined(separator: ", "))
                }
                return kind
            }
            let sort = try input.pick("sort", from: ["newest", "oldest", "edited"]) ?? "newest"
            let limit = try input.number("limit", 1...500) ?? 50, offset = try input.number("offset", 0...1_000_000) ?? 0
            let words = query.map { $0.split(whereSeparator: \.isWhitespace).map(String.init) } ?? []
            return try await withJournal(store) {
                let journal = try journalName.map { try store.info(store.journalObject($0)) }
                let names = try Dictionary(uniqueKeysWithValues: store.journalObjects().map { (JournalStore.id($0), store.name($0)) })
                var matches = try store.entryObjects(deleted: deleted).map(store.info).filter { entry in
                    if bookmarked && !entry.bookmarked { return false }
                    if let journal, !journal.isDefault, !entry.journals.contains(journal.id) { return false }
                    if let after, entry.date < after { return false }
                    if let before, entry.date >= before { return false }
                    if !kinds.isEmpty {
                        let present = Set(entry.assets.filter { !$0.hidden }.map { AssetDetails.kind($0.kind) })
                        let wanted = kinds.contains { kind in
                            switch kind {
                            case "any": !present.isEmpty
                            case "none": present.isEmpty
                            default: present.contains(kind)
                            }
                        }
                        if !wanted { return false }
                    }
                    if !words.isEmpty {
                        let haystack = ([entry.title, entry.text, entry.prompt ?? ""] + entry.assets.map(\.searchText) + entry.journals.compactMap { names[$0] })
                            .joined(separator: " ")
                        if !words.allSatisfy({ haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }) { return false }
                    }
                    return true
                }
                switch sort {
                case "oldest": matches.sort { $0.date < $1.date }
                case "edited": matches.sort { ($0.edited ?? $0.date) > ($1.edited ?? $1.date) }
                default: matches.sort { $0.date > $1.date }
                }
                let page = Array(matches.dropFirst(offset).prefix(limit))
                var result: [String: JSON] = [
                    "entries": .array(page.map { Output.summary($0, journals: names) }), "total": .int(matches.count),
                    "now": .string(Output.stamp(Date())), "time_zone": .string(TimeZone.current.identifier),
                ]
                if offset + page.count < matches.count { result["next_offset"] = .int(offset + page.count) }
                return ToolAnswer(JSON.object(result).text)
            }
        },

        Tool("read_entry", title: "Read journal entries",
             summary: """
                 Reads entries in full: the text as Markdown, the date, journal, bookmark, writing prompt, and each \
                 attachment's details (places, State of Mind, workouts, music, a recording's transcript, …), with \
                 the version edit_entry and delete_entry take. ![…](attachment:id) placeholders mark attachments \
                 placed in the text; read_attachment opens any attachment.
                 """,
             input: Schema.object([
                 "id": Schema.text("Entry id"),
                 "ids": Schema.texts("Several entries, up to 20"),
             ]), effect: .reads) { fields in
            let input = Input(fields)
            let id = try input.text("id"), ids = try input.texts("ids")
            guard (id == nil) != (ids == nil) else { throw BadInput("give id or ids") }
            let wanted = ids ?? [id!]
            guard (1...20).contains(wanted.count) else { throw BadInput("ids takes 1 to 20 entries") }
            return try await withJournal(store) {
                let names = try Dictionary(uniqueKeysWithValues: store.journalObjects().map { (JournalStore.id($0), store.name($0)) })
                let entries = try wanted.map { reference throws(JournalError) -> JSON in
                    let object = try store.entryObject(reference)
                    return Output.entry(store.info(object), markdown: store.markdown(object).0, journals: names)
                }
                return ToolAnswer((ids == nil ? entries[0] : JSON.object(["entries": .array(entries)])).text)
            }
        },

        Tool("read_attachment", title: "Read an attachment",
             summary: """
                 Opens one of an entry's attachments (its id from read_entry): photos, a frame of a video, audio \
                 recordings (with Journal's transcript), and the details of places, State of Mind, workouts, music \
                 and the rest.
                 """,
             input: Schema.object([
                 "id": Schema.text("Attachment id"),
                 "text_only": Schema.flag("Only the details, no images or audio"),
             ], required: ["id"]), effect: .reads) { fields in
            let input = Input(fields)
            let reference = try input.requiredText("id").uppercased()
            let textOnly = try input.flag("text_only") ?? false
            return try await withJournal(store) {
                for object in try store.entryObjects(deleted: nil) {
                    let entry = store.info(object)
                    guard let asset = entry.assets.first(where: { $0.id == reference || (reference.count >= 8 && $0.id.hasPrefix(reference)) }) else { continue }
                    return await Media.answer(asset, in: entry, textOnly: textOnly)
                }
                throw JournalError.notFound("an attachment with the id \(reference); read_entry lists an entry's attachments")
            }
        },
    ]
}
