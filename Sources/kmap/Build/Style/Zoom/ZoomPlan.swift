import Foundation

/// Which rung each family of features starts on.
///
/// The two built-in plans hold the ladders as measured; they cannot be edited or deleted,
/// and editing one makes a copy. A move is counted in rungs of the ladder the plan is built
/// on, never in bits — see `ZoomRungs`. Positive is coarser.
struct ZoomPlan: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    /// Which ladder this plan populates. A plan is only meaningful against one: a window is
    /// a pair of indexes into it, and the two ladders have different rungs.
    var levelsID: String

    /// The rungs a family is drawn on: a run, not a set.
    ///
    /// A style rule carries one `resolution`, optionally as a range — `[0x0c resolution
    /// 23-19]` — and a range is contiguous by construction, so a gap cannot be expressed.
    struct Window: Codable, Equatable {
        /// Rung indexes: finest is the smaller, since rung 0 is the closest zoom.
        var finest: Int
        var coarsest: Int

        var rungs: ClosedRange<Int> { min(finest, coarsest)...max(finest, coarsest) }
        func contains(_ rung: Int) -> Bool { rungs.contains(rung) }
        var count: Int { rungs.count }
    }

    /// Family id to the rungs it is drawn on. Absent means as measured, so a plan that
    /// changes one thing stores one entry.
    var windows: [String: Window] = [:]

    var isBuiltin: Bool { ZoomPlan.builtins.contains { $0.id == id } }

    /// Written out because the lenient decoder below takes the memberwise one away.
    init(id: String, name: String, levelsID: String, windows: [String: Window] = [:]) {
        self.id = id
        self.name = name
        self.levelsID = levelsID
        self.windows = windows
    }

    /// Decodes leniently: the synthesised decoder throws on a missing key even where the
    /// property has a default, and one throw would lose every plan in the settings file.
    /// Only the name and the ladder are required; everything else falls back.
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try box.decodeIfPresent(String.self, forKey: .name) ?? "Zoom plan"
        levelsID = try box.decodeIfPresent(String.self, forKey: .levelsID)
            ?? LevelsProfile.smooth.id
        // Plans written while this was a per-family shift carry `shifts` and no `windows`.
        // A shift cannot become a window without the style to measure against, so it is
        // dropped and the plan reads as unmodified.
        windows = try box.decodeIfPresent([String: Window].self, forKey: .windows) ?? [:]
    }

    func window(_ family: ZoomFamily) -> Window? { windows[family.id] }

    mutating func setWindow(_ window: Window?, for family: ZoomFamily) {
        windows[family.id] = window
    }

    /// Whether the plan moves anything, which is what tells an unmodified plan from one
    /// worth running a pass for.
    var movesAnything: Bool { !windows.isEmpty }

    // MARK: The ones that ship

    static let asMeasured = ZoomPlan(id: "as-measured", name: "Default",
                                     levelsID: LevelsProfile.smooth.id)
    static let standard = ZoomPlan(id: "standard-as-is", name: "Default, 4 levels",
                                   levelsID: LevelsProfile.standard.id)

    static let builtins = [asMeasured, standard]

    /// The plan a map is built with when none has been chosen: the built-in one for the
    /// ladder the recipe names.
    static func builtin(forLevels id: String) -> ZoomPlan {
        builtins.first { $0.levelsID == id } ?? asMeasured
    }
}

extension SettingsStore {
    /// Every plan there is: the two that ship, then whatever has been made, by name.
    var zoomPlans: [ZoomPlan] {
        ZoomPlan.builtins + settings.zoomPlans.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    func zoomPlan(_ id: String) -> ZoomPlan? { zoomPlans.first { $0.id == id } }

    /// The plan to build with. Falls back to what ships for the ladder, so a plan deleted
    /// after a profile named it leaves the map buildable rather than broken.
    func zoomPlan(_ id: String, forLevels levelsID: String) -> ZoomPlan {
        guard let found = zoomPlan(id), found.levelsID == levelsID else {
            return ZoomPlan.builtin(forLevels: levelsID)
        }
        return found
    }

    /// A copy of `plan` under a new name: how editing a built-in works, and the only way a
    /// new plan is made.
    func copyZoomPlan(_ plan: ZoomPlan, named name: String) -> ZoomPlan {
        var copy = plan
        copy.id = UUID().uuidString
        copy.name = uniqueZoomPlanName(name)
        update { $0.zoomPlans.append(copy) }
        return copy
    }

    func saveZoomPlan(_ plan: ZoomPlan) {
        guard !plan.isBuiltin else { return }
        update {
            if let at = $0.zoomPlans.firstIndex(where: { $0.id == plan.id }) {
                $0.zoomPlans[at] = plan
            } else {
                $0.zoomPlans.append(plan)
            }
        }
    }

    func renameZoomPlan(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let unique = uniqueZoomPlanName(trimmed, ignoring: id)
        update {
            guard let at = $0.zoomPlans.firstIndex(where: { $0.id == id }) else { return }
            $0.zoomPlans[at].name = unique
        }
    }

    /// Removes a plan. The built-in ones are not held in the settings file and so cannot
    /// be reached from here.
    @discardableResult
    func deleteZoomPlan(_ id: String) -> Bool {
        guard let at = settings.zoomPlans.firstIndex(where: { $0.id == id }) else { return false }
        update { $0.zoomPlans.remove(at: at) }
        return true
    }

    func uniqueZoomPlanName(_ wanted: String, ignoring id: String? = nil) -> String {
        let trimmed = wanted.trimmingCharacters(in: .whitespaces)
        let base = trimmed.isEmpty ? "Zoom plan" : trimmed
        let taken = Set(zoomPlans.filter { $0.id != id }.map { $0.name.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var n = 2
        while taken.contains("\(base.lowercased()) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}
