import SwiftUI
import os

struct AIChoiceStepView: View {
    @Bindable var onboardingManager: OnboardingManager
    @State private var apiKey: String = ""
    @State private var apiKeySaved = false
    @State private var geminiKey: String = ""
    @State private var geminiKeySaved = false
    @State private var openaiKey: String = ""
    @State private var openaiKeySaved = false
    @State private var zaiKey: String = ""
    @State private var zaiKeySaved = false
    @State private var isTesting = false
    @State private var testResult: String?

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: "brain.head.profile")
                .font(.system(size: 56))
                .foregroundStyle(Color.appAccent)

            Text("AI Summaries")
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundStyle(Color.appTextPrimary)

            Text("Choose how you'd like Meeting Manager to generate summaries, action items, and insights from your meetings.")
                .font(.body)
                .foregroundStyle(Color.appTextSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            VStack(spacing: 12) {
                aiOptionCard(
                    icon: "cloud",
                    title: "Claude AI",
                    description: "Cloud-based. Highest quality summaries. Requires an Anthropic API key.",
                    choice: .claude,
                    isSelected: onboardingManager.aiChoice == .claude
                )

                aiOptionCard(
                    icon: "sparkles",
                    title: "Google Gemini",
                    description: "Cloud-based. Fast, high-quality summaries. Requires a Google Gemini API key.",
                    choice: .gemini,
                    isSelected: onboardingManager.aiChoice == .gemini
                )

                aiOptionCard(
                    icon: "bolt.horizontal.circle",
                    title: "OpenAI",
                    description: "Cloud-based. GPT models. Requires an OpenAI API key.",
                    choice: .openai,
                    isSelected: onboardingManager.aiChoice == .openai
                )

                aiOptionCard(
                    icon: "globe.asia.australia",
                    title: "z.ai (GLM)",
                    description: "Cloud-based. Zhipu GLM models. Requires a z.ai API key.",
                    choice: .zai,
                    isSelected: onboardingManager.aiChoice == .zai
                )

                aiOptionCard(
                    icon: "desktopcomputer",
                    title: "On-Device (Ollama)",
                    description: "Fully local. No data leaves your Mac. Requires ~3 GB download.",
                    choice: .local,
                    isSelected: onboardingManager.aiChoice == .local
                )

                aiOptionCard(
                    icon: "minus.circle",
                    title: "No AI Summaries",
                    description: "Record and transcribe only. You can enable AI later in Settings.",
                    choice: .none,
                    isSelected: onboardingManager.aiChoice == .none
                )
            }
            .frame(maxWidth: 480)

            // Cloud AI key entry (shown when the respective provider is selected)
            if onboardingManager.aiChoice == .claude {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Anthropic API Key")
                        .font(.headline)
                        .foregroundStyle(Color.appTextPrimary)

                    HStack(spacing: 8) {
                        SecureField("sk-ant-...", text: $apiKey)
                            .textFieldStyle(.roundedBorder)

                        Button("Save") {
                            saveAPIKey()
                        }
                        .disabled(apiKey.isEmpty)

                        Button {
                            testConnection()
                        } label: {
                            if isTesting {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("Test")
                            }
                        }
                        .disabled(!apiKeySaved || isTesting)
                    }

                    if apiKeySaved {
                        Label("Key saved", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.appSuccess)
                    }

                    if let testResult {
                        Text(testResult)
                            .font(.caption)
                            .foregroundStyle(testResult.contains("Success") ? Color.appSuccess : Color.appWarning)
                    }

                    Link("Get your API key at console.anthropic.com →",
                         destination: URL(string: "https://console.anthropic.com")!)
                        .font(.caption)
                        .foregroundStyle(Color.appAccent)
                }
                .padding(16)
                .background(Color.appSurface)
                .cornerRadius(12)
                .frame(maxWidth: 480)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if onboardingManager.aiChoice == .gemini {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Google Gemini API Key").font(.headline).foregroundStyle(Color.appTextPrimary)
                    HStack(spacing: 8) {
                        SecureField("AIza...", text: $geminiKey).textFieldStyle(.roundedBorder)
                        Button("Save") { saveGeminiKey() }.disabled(geminiKey.isEmpty)
                    }
                    if geminiKeySaved {
                        Label("Key saved", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(Color.appSuccess)
                    }
                    Link("Get your API key at aistudio.google.com →", destination: URL(string: "https://aistudio.google.com/apikey")!)
                        .font(.caption).foregroundStyle(Color.appAccent)
                }
                .padding(16).background(Color.appSurface).cornerRadius(12).frame(maxWidth: 480)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if onboardingManager.aiChoice == .openai {
                VStack(alignment: .leading, spacing: 8) {
                    Text("OpenAI API Key").font(.headline).foregroundStyle(Color.appTextPrimary)
                    HStack(spacing: 8) {
                        SecureField("sk-...", text: $openaiKey).textFieldStyle(.roundedBorder)
                        Button("Save") { saveOpenAIKey() }.disabled(openaiKey.isEmpty)
                    }
                    if openaiKeySaved {
                        Label("Key saved", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(Color.appSuccess)
                    }
                    Link("Get your API key at platform.openai.com →", destination: URL(string: "https://platform.openai.com/api-keys")!)
                        .font(.caption).foregroundStyle(Color.appAccent)
                }
                .padding(16).background(Color.appSurface).cornerRadius(12).frame(maxWidth: 480)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if onboardingManager.aiChoice == .zai {
                VStack(alignment: .leading, spacing: 8) {
                    Text("z.ai API Key").font(.headline).foregroundStyle(Color.appTextPrimary)
                    HStack(spacing: 8) {
                        SecureField("...", text: $zaiKey).textFieldStyle(.roundedBorder)
                        Button("Save") { saveZaiKey() }.disabled(zaiKey.isEmpty)
                    }
                    if zaiKeySaved {
                        Label("Key saved", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(Color.appSuccess)
                    }
                    Link("Get your API key at z.ai →", destination: URL(string: "https://z.ai")!)
                        .font(.caption).foregroundStyle(Color.appAccent)
                }
                .padding(16).background(Color.appSurface).cornerRadius(12).frame(maxWidth: 480)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.2), value: onboardingManager.aiChoice)
    }

    private func aiOptionCard(icon: String, title: String, description: String, choice: OnboardingManager.AIChoice, isSelected: Bool) -> some View {
        Button {
            onboardingManager.aiChoice = choice
            applyChoice(choice)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(isSelected ? Color.appAccent : Color.appTextSecondary)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(Color.appTextPrimary)

                    Text(description)
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.appAccent : Color.appTextTertiary)
            }
            .padding(14)
            .background(isSelected ? Color.appAccent.opacity(0.08) : Color.appSurface)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.appAccent.opacity(0.4) : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func applyChoice(_ choice: OnboardingManager.AIChoice) {
        Task {
            let db = AppDatabase.shared.writer
            var settings = (try? await db.read { db in
                try AppSettings.fetchOne(db, key: 1)
            }) ?? AppSettings.default

            switch choice {
            case .claude:
                settings.aiProvider = .claude
            case .gemini:
                settings.aiProvider = .gemini
            case .openai:
                settings.aiProvider = .openai
            case .zai:
                settings.aiProvider = .zai
            case .local:
                settings.aiProvider = .local
            case .none:
                settings.aiProvider = .none
            }

            try? await db.write { db in
                try settings.save(db)
            }
        }
    }

    private func saveAPIKey() {
        guard !apiKey.isEmpty else { return }
        do {
            try KeychainHelper.save(apiKey, forKey: KeychainHelper.Key.claudeAPIKey)
            apiKeySaved = true
        } catch {
            Logger.general.error("Failed to save API key: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func saveGeminiKey() {
        guard !geminiKey.isEmpty else { return }
        do {
            try KeychainHelper.save(geminiKey, forKey: KeychainHelper.Key.geminiAPIKey)
            geminiKeySaved = true
        } catch {
            Logger.general.error("Failed to save Gemini key: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func saveOpenAIKey() {
        guard !openaiKey.isEmpty else { return }
        do {
            try KeychainHelper.save(openaiKey, forKey: KeychainHelper.Key.openAIAPIKey)
            openaiKeySaved = true
        } catch {
            Logger.general.error("Failed to save OpenAI key: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func saveZaiKey() {
        guard !zaiKey.isEmpty else { return }
        do {
            try KeychainHelper.save(zaiKey, forKey: KeychainHelper.Key.zaiAPIKey)
            zaiKeySaved = true
        } catch {
            Logger.general.error("Failed to save z.ai key: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func testConnection() {
        isTesting = true
        testResult = nil

        Task {
            let claude = ClaudeService()
            let success = await claude.testConnection()
            isTesting = false
            testResult = success ? "Success — Claude API is connected!" : "Failed — check your API key"
        }
    }
}
