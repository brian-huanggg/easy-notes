import SwiftUI
import UniformTypeIdentifiers

/// 匯出給 Anki 的資料夾：每種筆記類型一個 .txt
struct AnkiExportFolder: FileDocument {
    static let readableContentTypes: [UTType] = [.folder]

    let files: [AnkiExport.File]

    init(files: [AnkiExport.File]) {
        self.files = files
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.featureUnsupported)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        var children: [String: FileWrapper] = [:]
        for file in files {
            let wrapper = FileWrapper(regularFileWithContents: Data(file.text.utf8))
            wrapper.preferredFilename = file.name
            children[file.name] = wrapper
        }
        return FileWrapper(directoryWithFileWrappers: children)
    }
}
