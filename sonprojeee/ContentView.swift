//
//  ContentView.swift
//  sonprojeee
//
//  Created by Adil Emre Karayürek on 16.04.2025.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack {
            Image(systemName: "globe")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text(NSLocalizedString("Hello, world!", comment: "Default content text"))
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
