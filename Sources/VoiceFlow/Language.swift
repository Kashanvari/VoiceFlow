/// The language you dictate in, chosen in the menu-bar menu or Settings. English uses Parakeet and the AI clean-up;
/// Farsi uses Whisper and writes Persian script (the clean-up model and learning are English-only).
enum Language: String, CaseIterable, Identifiable {
    case english, farsi

    var id: String { rawValue }

    var title: String {
        switch self {
        case .english: return "English"
        case .farsi: return "Farsi (فارسی)"
        }
    }

    /// Shown in the listening bubble so you can see which language is on.
    var tag: String? { self == .farsi ? "فا" : nil }
}

/// Where the Farsi speech model is. It loads only once Farsi is chosen, since it takes about 1.5 GB of memory.
enum FarsiModelStatus: Equatable {
    case notLoaded, downloading(Double), loading, ready, failed(String)
}
