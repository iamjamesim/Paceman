import SwiftUI

/// Response controls are part of the task page, with no nested navigation or modal.
struct InteractionDetail: View {
    let item: PendingInput
    @ObservedObject var inbox: InteractionInbox
    let theme: CompanionTheme
    var taskTitle = ""
    var taskContext = ""
    var openFailure: String?
    var preview = false
    var sampleResponse: ((InputSubmission) throws -> Void)? = nil
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var phase
    @State private var answers: [String: InputAnswer] = [:]
    @State private var submission: InputSubmission?
    @State private var sending = false
    @State private var sent = false
    @State private var retryable = false
    @State private var message: String?
    @FocusState private var focusedQuestion: String?
    private var ready: Bool { item.request.questions.allSatisfy { (answers[$0.id] ?? InputAnswer()).valid(for: $0) } }
    private var editable: Bool { submission == nil && !sending && inbox.isCurrent(item) && phase == .active }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if typeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(taskTitle).companionText(.title, theme: theme)
                            Text(taskContext).companionText(.supporting, theme: theme)
                        }
                    }
                    if sent {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(submission?.action == "release" ? "Continue on your computer" : "Your response")
                                .companionText(.prompt, theme: theme)
                            if let submission, submission.action == "answer" {
                                ForEach(item.request.questions) { question in
                                    if let answer = submission.answers[question.id] {
                                        Text(answer.text.isEmpty ? answer.selected.map { question.options[$0].label }.joined(separator: ", ") : answer.text)
                                            .companionText(.body, theme: theme)
                                    }
                                }
                            }
                            if let submission, submission.action != "answer" && submission.action != "release" {
                                Text(submission.action == "allowOnce" ? "Allowed once" : "Declined").companionText(.body, theme: theme)
                            }
                            Text(sampleResponse == nil ? "Waiting for the agent’s next update." : "Saved on this phone.")
                                .companionText(.body, theme: theme)
                        }
                    } else {
                        if !item.request.title.isEmpty || !item.request.detail.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                if !item.request.title.isEmpty { Text(item.request.title).companionText(.prompt, theme: theme) }
                                if !item.request.detail.isEmpty {
                                    Text(item.request.detail).companionText(.body, theme: theme).textSelection(.enabled)
                                }
                            }
                        }
                        ForEach(item.request.questions) { question in questionForm(question) }
                        if let message { Text(message).companionText(.body, theme: theme) }
                        if !sending && !retryable && !editable && message == nil {
                            Text("This request is no longer available. Continue on your computer.").companionText(.body, theme: theme)
                        }
                    }
                    if let openFailure { Text(openFailure).companionText(.body, theme: theme) }
                    if sampleResponse != nil {
                        Text("Sample task · nothing is sent to an agent.").companionText(.supporting, theme: theme)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, CompanionLayout.pageInset).padding(.vertical, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !sent && (sending || retryable || editable) {
                    responseActions
                        .padding(.horizontal, CompanionLayout.pageInset).padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .background(theme.canvas)
                }
            }
        }
    }

    @ViewBuilder private var responseActions: some View {
        VStack(spacing: 8) {
            if sending {
                ProgressView("Sending response…").companionText(.body, theme: theme)
                    .frame(minHeight: 44)
            } else if retryable {
                InputActionButton(title: "Retry same response", theme: theme) {
                    if let submission { send(submission) }
                }.disabled(phase != .active)
            } else if editable {
                if item.request.kind == "approval" {
                    InputActionButton(title: "Allow once", theme: theme) { respond("allowOnce") }
                    InputActionButton(title: "Decline", theme: theme, primary: false) { respond("deny") }
                } else {
                    InputActionButton(title: "Send answer", theme: theme) { respond("answer") }
                        .disabled(!ready)
                }
                if sampleResponse == nil {
                    Button { respond("release") } label: {
                        Text("Continue on computer").companionText(.body, theme: theme)
                            .frame(minHeight: 44).contentShape(Rectangle())
                    }
                }
            }
        }
    }

    private func questionForm(_ question: InteractionQuestion) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text(question.prompt).companionText(.prompt, theme: theme)
                if question.multiple { Text("Choose one or more, or write a response.").companionText(.body, theme: theme) }
            }
            VStack(spacing: 0) {
                ForEach(question.options.indices, id: \.self) { index in
                    let option = question.options[index]
                    let selected = answers[question.id]?.selected.contains(index) == true
                    Button {
                        var value = answers[question.id] ?? InputAnswer()
                        value.text = ""
                        if question.multiple {
                            if selected { value.selected.removeAll { $0 == index } }
                            else { value.selected.append(index); value.selected.sort() }
                        } else { value.selected = selected ? [] : [index] }
                        answers[question.id] = value
                        focusedQuestion = nil
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Image(systemName: question.multiple ? (selected ? "checkmark.square.fill" : "square") : (selected ? "largecircle.fill.circle" : "circle"))
                                .font(.body)
                                .foregroundStyle(selected ? theme.tint : theme.secondaryInk).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(option.label).companionText(.body, theme: theme)
                                if !option.description.isEmpty { Text(option.description).companionText(.supporting, theme: theme) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }.padding(.vertical, 8).frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(!editable)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            TextField(question.options.isEmpty ? "Your answer" : "Or write a response", text: Binding(get: { answers[question.id]?.text ?? "" }, set: { text in
                answers[question.id] = InputAnswer(selected: [], text: text)
            }), axis: .vertical)
                .companionText(.body, theme: theme)
                .fixedSize(horizontal: false, vertical: true)
                .focused($focusedQuestion, equals: question.id)
                .accessibilityLabel("Your answer: " + question.prompt)
                .padding(12)
                .background(theme.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                .disabled(!editable)
        }
    }

    private func respond(_ action: String) {
        guard inbox.isCurrent(item), phase == .active else { return }
        let value = InputSubmission(generation: item.generation, requestID: item.request.id,
            version: item.request.version, idempotencyKey: UUID().uuidString, action: action,
            answers: action == "answer" ? answers : [:])
        focusedQuestion = nil
        submission = value
        send(value)
    }
    private func send(_ value: InputSubmission) {
        sending = true; retryable = false; message = nil
        Task { @MainActor in
            defer { sending = false }
            do {
                if let sampleResponse { try sampleResponse(value) }
                else if !preview { try await SourceClient().submitInput(value, source: item.source) }
                sent = true
                inbox.didSubmit(item, action: value.action)
            } catch {
                if sampleResponse != nil {
                    message = "Your response couldn’t be saved. Try again."
                    retryable = true
                } else if let error = error as? HubError, case .http(let status) = error,
                   [400, 401, 404, 409, 410, 422].contains(status) {
                    message = "This response could not be confirmed. Check the task on your computer."
                } else {
                    message = "Delivery is unconfirmed. Retry the same response, or check the task on your computer."
                    retryable = true
                }
            }
        }
    }
}

/// Bottom decision controls have a generous baseline and expand with Dynamic Type.
private struct InputActionButton: View {
    let title: String
    let theme: CompanionTheme
    var primary = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(CompanionTextRole.button.font)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .padding(.vertical, CompanionLayout.actionVerticalInset).padding(.horizontal, 16)
                .frame(minHeight: CompanionLayout.actionMinimumHeight)
                .foregroundStyle(primary ? theme.canvas : theme.ink)
                .background(primary ? theme.ink : theme.ink.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain)
    }
}
