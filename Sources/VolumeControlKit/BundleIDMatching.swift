public enum BundleIDMatching {
    /// Ancestor bundle IDs for a helper process, nearest first, e.g.
    /// `com.google.Chrome.helper.renderer` → `com.google.Chrome.helper`, `com.google.Chrome`.
    /// Never shortens to a bare vendor prefix like `com.google`.
    public static func parentCandidates(for bundleID: String) -> [String] {
        var components = bundleID.split(separator: ".").map(String.init)
        var candidates: [String] = []
        while components.count > 3 {
            components.removeLast()
            candidates.append(components.joined(separator: "."))
        }
        return candidates
    }
}
