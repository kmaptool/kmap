import Foundation

extension StyleRecovery {
    /// The strongest claim made on each meaning over every code, which each code's own
    /// claim is measured against.
    struct Leaders {
        /// Per meaning: a meaning belongs to the code that mostly draws it.
        var meaning: [String: Int] = [:]
        /// Per tag: a code drawing few of a chain's many tags is a stray on the chain, yet
        /// the rightful owner of its own tag - bollards under the gates.
        var tag: [String: Int] = [:]
        /// The finest zoom each meaning is drawn at: a stroke that stops short of it is the
        /// same meaning at another zoom, not a stray.
        var finest: [String: Int] = [:]
        /// Per class, buildings apart from open ground: a yard is no stray of the buildings
        /// standing in it.
        var classed: [String: Int] = [:]
        /// Per tag of a fill, the most drawn on buildings and on open ground.
        var built: [String: Int] = [:]
        var open: [String: Int] = [:]

        /// Tallied over every code read.
        init(of readings: [CodeReading]) {
            for entry in readings {
                for (bucket, meaning) in entry.buckets {
                    self.meaning[bucket] = max(self.meaning[bucket] ?? 0, meaning.count)
                    let classed = StyleRecovery.classKey(bucket, meaning)
                    self.classed[classed] = max(self.classed[classed] ?? 0, meaning.count)
                    if let finest = entry.code.resolutions.keys.max() {
                        self.finest[bucket] = max(self.finest[bucket] ?? 0, finest)
                    }
                    for (tag, count) in meaning.tags {
                        self.tag["\(entry.code.kind.rawValue)@\(tag)"] = max(
                            self.tag["\(entry.code.kind.rawValue)@\(tag)"] ?? 0,
                            count
                        )
                        guard entry.code.kind == .area else { continue }
                        let key = "\(entry.code.kind.rawValue)@\(tag)"
                        if meaning.isBuilt {
                            self.built[key] = max(self.built[key] ?? 0, count)
                        } else {
                            self.open[key] = max(self.open[key] ?? 0, count)
                        }
                    }
                }
            }
        }

        /// The tags drawn on buildings, and on open ground: only where that class is a
        /// real share of the tag, so 3 mistagged houses do not make the woods built.
        func classedTags() -> (built: Set<String>, open: Set<String>) {
            func real(_ mine: Int?, against other: Int?) -> Bool {
                let mine = mine ?? 0
                return mine >= StyleRecovery.fewestStroke && Double(mine) >= StyleRecovery.stray * Double(other ?? 0)
            }
            return (
                Set(built.keys.filter { real(built[$0], against: open[$0]) }),
                Set(open.keys.filter { real(open[$0], against: built[$0]) })
            )
        }
    }
}
