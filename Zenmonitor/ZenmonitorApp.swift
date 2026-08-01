//
//  ZenmonitorApp.swift
//  Zenmonitor
//
//  Zenmonitor 菜单栏多源监控入口
//

import SwiftUI

@main
struct ZenmonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
