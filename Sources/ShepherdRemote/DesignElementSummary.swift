import Foundation
import ShepherdProtocol

/// What an element of a board is and holds, as the @ picker's rows say it under their titles
/// (RefAtElements: "funnel bars · 5 steps", "list · 5 rows", "KPI tile · 1 of 4",
/// "chips · All platforms, Web, iOS, Android"), read from the board's source alone.
///
/// A kind noun, then the first that applies:
/// - **What it repeats:** the first run of like children (same tag and name) found in it or
///   just under it (three levels down at most), counted with their noun: their `data-el` name, a
///   loop's `as`, else "row", "bar" or "card" by what they draw. The kind is the holder's own
///   name when the run is under the element, else what the run makes it: a list, a table, a grid,
///   bars. Chips (buttons, links or pills of a few words) are listed by their words instead.
/// - **Its place among like siblings:** "1 of 4", its kind qualified by its parent's name.
/// - **Else** what it is, and how many elements it holds.
public struct DesignElementSummary {
    let template: DesignTemplate
    let names: [Int: String]
    let roles: [Int: String]
    let styles: [Int: DesignInlineStyle]
    let loops: [Int: (list: String?, item: String?)]
    /// Each element's children as the board draws them: an `sc-if` is looked through.
    let children: [[Int]]
    /// Each element's parent as the board draws it: an `sc-if` is looked through.
    let parents: [Int?]

    /// The runtime's and the markup's scaffold, never a piece of the design.
    public static let scaffold: Set<String> = ["helmet", "style", "script", "title", "template", "sc-for", "sc-if", "dc-import", "x-dc",
                                               "br", "wbr"]
    /// Chips hold a few words each.
    static let chipWords = 24
    /// Chips listed by their words: at most this many, then how many more.
    static let chipsListed = 4
    /// How far under an element its repeated children are looked for.
    static let depth = 3

    public init?(source: String) {
        guard let template = DesignTemplate(board: source) else { return nil }
        let loopLists = DesignStyleEdit.attributes("list", in: source)
        let loopItems = DesignStyleEdit.attributes("as", in: source)
        self.init(template: template, names: DesignStyleEdit.attributes("data-el", in: source), roles: DesignStyleEdit.attributes("role", in: source),
                  styles: DesignStyleEdit.styles(in: source), loopLists: loopLists, loopItems: loopItems)
    }

    init(template: DesignTemplate, names: [Int: String], roles: [Int: String], styles: [Int: DesignInlineStyle],
         loopLists: [Int: String], loopItems: [Int: String]) {
        self.template = template
        self.names = names.filter { !$0.value.contains("{{") && !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        self.roles = roles
        self.styles = styles
        var loops: [Int: (list: String?, item: String?)] = [:]
        for element in template.elements where element.name == "sc-for" {
            let list = loopLists[element.tid].map { $0.replacingOccurrences(of: "{{", with: "").replacingOccurrences(of: "}}", with: "")
                .trimmingCharacters(in: .whitespaces) }
            loops[element.tid] = (list?.isEmpty == false ? list : nil, loopItems[element.tid].flatMap { $0.isEmpty ? nil : $0 })
        }
        self.loops = loops
        let count = template.elements.count
        var parents = [Int?](repeating: nil, count: count)
        var children = [[Int]](repeating: [], count: count)
        for element in template.elements {
            var parent = element.parent
            while let p = parent, template.elements[p].name == "sc-if" { parent = template.elements[p].parent }
            parents[element.tid] = parent
            if element.name != "sc-if", let parent { children[parent].append(element.tid) }
        }
        self.parents = parents
        self.children = children
    }

    /// The line under element `tid`'s title.
    public func detail(_ tid: Int) -> String {
        guard template.elements.indices.contains(tid) else { return "" }
        if let run = run(under: tid) { return describe(run, of: tid) }
        if let place = place(of: tid) { return place }
        let inside = insideCount(tid)
        return [descriptor(tid), inside > 0 ? "\(inside) inside" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Runs

    enum RunKind: Equatable {
        case chips, bars, rows
        /// A loop draws its members: how many is the data's.
        case loop(list: String?, item: String?)
    }

    struct Run {
        var holder: Int
        var members: [Int]
        var kind: RunKind
    }

    /// The first run of like children in `tid` or under it, breadth first.
    func run(under tid: Int) -> Run? {
        var level = [tid]
        for _ in 0...Self.depth {
            var next: [Int] = []
            for holder in level {
                if let run = run(of: holder) { return run }
                next += children[holder].filter { !Self.scaffold.contains(template.elements[$0].name) || template.elements[$0].name == "sc-for" }
            }
            guard !next.isEmpty else { return nil }
            level = next
        }
        return nil
    }

    /// `holder`'s own run: its largest group of like children, when they repeat something (not
    /// the parts of one thing, like a tile's label and value).
    func run(of holder: Int) -> Run? {
        let kids = children[holder]
        if let loop = kids.first(where: { loops[$0] != nil }), let found = loops[loop] {
            return Run(holder: holder, members: children[loop], kind: .loop(list: found.list, item: found.item))
        }
        var groups: [String: [Int]] = [:]
        var order: [String] = []
        for kid in kids where !Self.scaffold.contains(template.elements[kid].name) {
            let key = signature(kid)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(kid)
        }
        guard let largest = order.map({ groups[$0]! }).max(by: { $0.count < $1.count }), largest.count >= 2 else { return nil }
        if largest.allSatisfy(isChip) { return Run(holder: holder, members: largest, kind: .chips) }
        if largest.allSatisfy(isBar) { return Run(holder: holder, members: largest, kind: .bars) }
        if largest.allSatisfy(isRow) { return Run(holder: holder, members: largest, kind: .rows) }
        return nil
    }

    func describe(_ run: Run, of tid: Int) -> String {
        let holderName = run.holder == tid ? nil : names[run.holder]
        switch run.kind {
        case .chips:
            let words = run.members.compactMap { template.labels[$0] }
            let listed = words.prefix(Self.chipsListed).joined(separator: ", ")
            let more = words.count > Self.chipsListed ? ", +\(words.count - Self.chipsListed)" : ""
            return (holderName ?? "chips") + " · " + listed + more
        case .bars:
            return (holderName ?? "bars") + " · " + Self.counted(run.members.count, "bar")
        case .rows:
            let noun = memberNoun(run.members[0])
            return (holderName ?? layoutNoun(run.holder)) + " · " + Self.counted(run.members.count, noun)
        case .loop(let list, let item):
            let noun = Self.plural(item ?? run.members.first.map(memberNoun) ?? "item")
            let kind = holderName ?? layoutNoun(run.holder)
            guard let list, list != noun else { return kind + " · repeated " + noun }
            return kind + " · " + noun + " from " + list
        }
    }

    // MARK: Places

    /// "1 of 4" among the siblings drawn like it, its kind qualified by its parent's name.
    func place(of tid: Int) -> String? {
        guard let parent = parents[tid] else { return nil }
        let key = signature(tid)
        let like = children[parent].filter { signature($0) == key }
        guard like.count >= 2, let index = like.firstIndex(of: tid) else {
            if template.elements[parent].name == "sc-for" { return kind(of: tid, qualifiedBy: parents[parent]) + " · repeated" }
            return nil
        }
        return kind(of: tid, qualifiedBy: parent) + " · \(index + 1) of \(like.count)"
    }

    func kind(of tid: Int, qualifiedBy parent: Int?) -> String {
        let own = names[tid] ?? noun(tid)
        guard let parent, let qualifier = names[parent], !own.localizedCaseInsensitiveContains(qualifier) else { return own }
        return qualifier + " " + own
    }

    // MARK: Words

    /// What a repeated member is called: its name, else by what it is.
    func memberNoun(_ tid: Int) -> String {
        if let name = names[tid] { return name }
        switch template.elements[tid].name {
        case "li", "tr", "dt": return "row"
        default: break
        }
        if isBar(tid) { return "bar" }
        if !children[tid].isEmpty, DesignReferenceReading.draws(styles[tid]) { return "card" }
        return "row"
    }

    /// What a run makes its holder: a list, a table, a grid, a row.
    func layoutNoun(_ tid: Int) -> String {
        switch template.elements[tid].name {
        case "table", "tbody", "thead", "tfoot": return "table"
        case "ul", "ol", "menu", "dl": return "list"
        default: break
        }
        let declarations = styles[tid]?.declarations ?? []
        func value(_ property: String) -> String? {
            declarations.last { $0.property == property }?.value.lowercased()
        }
        if let display = value("display"), display.contains("grid") { return "grid" }
        return "list"
    }

    /// What the element is where nothing repeats: a heading, a paragraph, else the canvas's noun.
    func descriptor(_ tid: Int) -> String {
        let tag = template.elements[tid].name
        if ["h1", "h2", "h3", "h4", "h5", "h6"].contains(tag) { return "heading" }
        if tag == "p" { return "paragraph" }
        return noun(tid)
    }

    /// The canvas's noun for it (card, group, text, button…).
    func noun(_ tid: Int) -> String {
        DesignReferenceReading.elementNoun(template.elements[tid], children: !children[tid].isEmpty, words: template.labels[tid] != nil,
                                           style: styles[tid], role: roles[tid])
    }

    /// Like siblings share a tag and a name.
    func signature(_ tid: Int) -> String {
        template.elements[tid].name + "|" + (names[tid] ?? "")
    }

    /// A button, a link, or a pill (a box it draws) of a few words and nothing laid out inside.
    func isChip(_ tid: Int) -> Bool {
        guard let words = template.labels[tid], words.count <= Self.chipWords else { return false }
        let tag = template.elements[tid].name
        let clickable = tag == "button" || tag == "a" || roles[tid]?.lowercased() == "button"
        return clickable || (DesignReferenceReading.draws(styles[tid]) && children[tid].allSatisfy { children[$0].isEmpty })
    }

    /// A box that draws a fill and holds nothing: a bar.
    func isBar(_ tid: Int) -> Bool {
        children[tid].isEmpty && template.labels[tid] == nil && DesignReferenceReading.draws(styles[tid])
    }

    /// A member that is a thing of its own: it holds elements, is a list's or a table's row, or is named.
    func isRow(_ tid: Int) -> Bool {
        ["li", "tr", "dt"].contains(template.elements[tid].name) || names[tid] != nil || !children[tid].isEmpty
    }

    func insideCount(_ tid: Int) -> Int {
        children[tid].reduce(0) { $0 + 1 + insideCount($1) }
    }

    static func counted(_ count: Int, _ noun: String) -> String {
        "\(count) " + (count == 1 ? noun : plural(noun))
    }

    /// An English plural of a noun's last word: steps, boxes, entries.
    static func plural(_ noun: String) -> String {
        let lower = noun.lowercased()
        if lower.hasSuffix("s") || lower.hasSuffix("x") || lower.hasSuffix("ch") || lower.hasSuffix("sh") { return noun + "es" }
        if lower.hasSuffix("y"), let before = lower.dropLast().last, !"aeiou".contains(before) { return noun.dropLast() + "ies" }
        return noun + "s"
    }
}
