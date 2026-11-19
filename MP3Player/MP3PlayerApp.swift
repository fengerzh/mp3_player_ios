import SwiftUI
import UIKit

@main
struct MP3PlayerApp: App {
    init() {
        UISlider.appearance().thumbTintColor = UIColor.systemBlue
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
