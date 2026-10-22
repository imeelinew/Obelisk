import ExtensionFoundation

extension AppExtensionPoint {
  @Definition static var obeliskUI: AppExtensionPoint {
    Name("BookmarkManager")
    UserInterface(true)
    Scope(restriction: .application)
  }
}
