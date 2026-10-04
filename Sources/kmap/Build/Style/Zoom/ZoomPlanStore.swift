import Foundation

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
