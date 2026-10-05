import Foundation

/// Localized strings of this module (rules in docs/architecture/translation.md).
/// `#bundle` must expand in each module itself, so every module keeps its own copy; it cannot be shared.
func L(_ value: String.LocalizationValue) -> String {
    String(localized: value, bundle: #bundle)
}
