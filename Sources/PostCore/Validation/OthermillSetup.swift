import CAMCore
import Foundation

/// What the Bantam Tools software (Othermill, #114) assumes of a program. The posts are recognised by id, which a project's copy
/// keeps, so a later change to the built-in's text cannot switch these rules off for saved projects.
public enum OthermillSetup {
    public static let postIDs: Set<String> = [BuiltInPosts.othermillInch.id, BuiltInPosts.othermillMM.id]
}
