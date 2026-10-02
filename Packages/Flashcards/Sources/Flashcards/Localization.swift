import Foundation

/// 這個模組的在地化字串（規則見 docs/architecture/translation.md）。
/// `#bundle` 要在各模組自己展開，所以每個模組各放一份，不能共用。
func L(_ value: String.LocalizationValue) -> String {
    String(localized: value, bundle: #bundle)
}
