import Foundation
import LoftLineKit
import UniformTypeIdentifiers

extension ImportService {


    static var allowedContentTypes: [UTType] {
        allExtensions.compactMap { UTType(filenameExtension: $0) }
    }
}
