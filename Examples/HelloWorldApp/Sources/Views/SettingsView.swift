//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import SwiftUI

// MARK: - Settings View

/// Settings view for configuring container options.
struct SettingsView: View {
    @Binding var imageName: String
    @Binding var port: String
    @Binding var cpuCores: Int
    @Binding var memoryMB: Int
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Text("Settings")
                .font(.title)
                .padding(.top)

            Form {
                TextField("Container Image", text: $imageName)
                    .textFieldStyle(.roundedBorder)

                TextField("Port", text: $port)
                    .textFieldStyle(.roundedBorder)

                Stepper("CPU Cores: \(cpuCores)", value: $cpuCores, in: 1...8)

                Picker("Memory", selection: $memoryMB) {
                    Text("256 MB").tag(256)
                    Text("512 MB").tag(512)
                    Text("1 GB").tag(1024)
                    Text("2 GB").tag(2048)
                    Text("4 GB").tag(4096)
                }
            }
            .padding()

            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .padding(.bottom)
        }
        .frame(width: 400, height: 320)
    }
}

// MARK: - Preview

#if DEBUG
struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView(
            imageName: .constant("node:20-alpine"),
            port: .constant("3000"),
            cpuCores: .constant(2),
            memoryMB: .constant(512)
        )
    }
}
#endif
