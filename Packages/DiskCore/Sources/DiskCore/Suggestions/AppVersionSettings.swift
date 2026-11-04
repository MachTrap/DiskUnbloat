import Foundation

/// Home-relative folders whose direct children are per-version settings and support data
/// of one application (`Blender/4.2`, `Blender/5.4`). Only the deep level selects from
/// them, older versions only — see `AutoSelectionSpec.deepRules`. Every entry is verified
/// against the vendor's documented macOS layout before it is listed here.
public enum AppVersionSettings {
    public static let locations: [String] = [
        // Blender keeps config, scripts, and add-ons per version:
        // ~/Library/Application Support/Blender/<major.minor>/
        "Library/Application Support/Blender",
        // Maya: ~/Library/Preferences/Autodesk/maya/<year>/ (prefs, scripts, shelves);
        // Maya.env and shared folders beside them are non-versioned and always stay.
        "Library/Preferences/Autodesk/maya",
        // Cinema 4D: ~/Library/Preferences/Maxon/Maxon Cinema 4D <year>_<id>/ per version.
        "Library/Preferences/Maxon",
        // Ableton Live: ~/Library/Preferences/Ableton/Live <x.y.z>/ per installed version.
        "Library/Preferences/Ableton",
    ]
}
