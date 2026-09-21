//
//  HomePlaceholderBlock.swift
//  Kline
//
//  A 档首页居中占位：标题 + 欢迎语。
//

import SwiftUI

struct HomePlaceholderBlock: View {
    var body: some View {
        VStack {
            Text("首页")
                .font(.title)
            Text("欢迎来到首页")
                .accessibilityIdentifier("home.welcome")
        }
        .frame(maxHeight: .infinity)
    }
}