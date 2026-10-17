import SwiftUI

/// Shared response content and bottom actions inside the current-task card.
struct InteractionDetail: View {
    let item: PendingInput
    @ObservedObject var inbox: InteractionInbox
    let theme: CompanionTheme
    var heading: TaskCardHeading? = nil
    var context: String? = nil
    var contentTopInset: CGFloat = 16
    var openSession: SessionOpenButton? = nil
    @Environment(\.scenePhase) private var phase
    @State private var answers: [String: InputAnswer] = [:]
    private var response: InputResponseState? { inbox.response(for: item) }
    private var submission: InputSubmission? { response?.submission }
    private var sending: Bool { response?.phase == .sending || inbox.isSubmitting(item) }
    private var sent: Bool { response?.phase == .submitted }
    private var retryable: Bool { response?.phase == .unconfirmed }
    private var message: String? { response?.message }
    @FocusState private var focusedQuestion: String?
    private var ready: Bool {
        item.request.questions.allSatisfy { (answers[$0.id] ?? InputAnswer()).valid(for: $0) }
            && item.answersFitWireLimit(answers)
    }
    private var validationMessage: String? {
        if answers.values.contains(where: { $0.text.unicodeScalars.count > 4096 }) {
            return "Keep each answer to 4,096 characters or fewer."
        }
        return item.answersFitWireLimit(answers) ? nil : "The combined answer is too long. Shorten it to send."
    }
    private var editable: Bool { response == nil && !sending && inbox.isCurrent(item) && phase == .active }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let heading { heading }
                    if let context { Text(context).companionText(.supporting, theme: theme) }
                    if (item.request.kind != "question" && !item.request.title.isEmpty) || !item.request.detail.isEmpty {
                        let directApproval = item.request.kind == "approval" && ApprovalDetailContent(item.request.detail).explanation.isEmpty
                        VStack(alignment: .leading, spacing: directApproval ? CompanionLayout.taskPromptSpacing : 8) {
                            if !item.request.title.isEmpty && item.request.kind != "question" {
                                Text(item.request.title).companionText(.cardTitle, theme: theme)
                                    .accessibilityAddTraits(.isHeader)
                            }
                            if !item.request.detail.isEmpty {
                                if item.request.kind == "approval" {
                                    approvalDetail
                                } else {
                                    Text(item.request.detail).companionText(.body, theme: theme).textSelection(.enabled)
                                }
                            }
                        }
                    }
                    ForEach(item.request.questions) { question in questionForm(question) }
                    if editable, let validationMessage {
                        Text(validationMessage).companionText(.body, theme: theme)
                    }
                    if let message { Text(message).companionText(.body, theme: theme) }
                    if !sent && !sending && !retryable && !editable && message == nil {
                        Text("This request is no longer available. Continue on your computer.").companionText(.body, theme: theme)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, CompanionLayout.pageInset)
                    .padding(.top, contentTopInset).padding(.bottom, 16)
                    .taskCardMeasure(.content)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if (!sent && (sending || retryable || editable)) || openSession != nil {
                    VStack(spacing: 8) {
                        if !sent && (sending || retryable || editable) { responseActions }
                        if let openSession { openSession }
                    }
                        .padding(.horizontal, CompanionLayout.pageInset).padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .background(theme.canvas)
                        .taskCardMeasure(.actions)
                }
            }
        }
        .onAppear {
            if let submission { answers = submission.answers }
        }
    }

    @ViewBuilder private var responseActions: some View {
        VStack(spacing: 8) {
            if sending {
                ProgressView("Sending response…").companionText(.body, theme: theme)
                    .frame(minHeight: 44)
            } else if retryable {
                InputActionButton(title: "Retry same response", theme: theme) {
                    inbox.retry(item)
                }.disabled(phase != .active)
            } else if editable {
                if item.request.kind == "approval" {
                    InputActionButton(title: "Allow once", theme: theme) { respond("allowOnce") }
                    InputActionButton(title: "Decline", theme: theme, primary: false) { respond("deny") }
                } else {
                    InputActionButton(title: "Send answer", theme: theme) { respond("answer") }
                        .disabled(!ready)
                }
            }
        }
    }

    private func questionForm(_ question: InteractionQuestion) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: CompanionLayout.taskPromptSpacing) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(question.prompt).companionText(.cardTitle, theme: theme)
                        .accessibilityAddTraits(.isHeader)
                    if question.multiple { Text("Choose one or more.").companionText(.body, theme: theme) }
                }
                if !question.options.isEmpty { questionChoices(question) }
            }
            TextField(question.options.isEmpty ? "Your answer" : "Or write a response", text: Binding(get: { answers[question.id]?.text ?? "" }, set: { text in
                guard (answers[question.id]?.text ?? "") != text else { return }
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

    private func questionChoices(_ question: InteractionQuestion) -> some View {
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
                            Text(option.label).companionText(.label, theme: theme)
                            if !option.description.isEmpty { Text(option.description).companionText(.supporting, theme: theme) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }.padding(.vertical, 8).frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(!editable)
                    .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private var approvalDetail: some View {
        let content = ApprovalDetailContent(item.request.detail)
        return VStack(alignment: .leading, spacing: 24) {
            if !content.explanation.isEmpty {
                Text(content.explanation).companionText(.body, theme: theme).textSelection(.enabled)
            }
            if let action = content.action {
                let presentation = ApprovalActionContent(action)
                VStack(alignment: .leading, spacing: 12) {
                    if !presentation.body.isEmpty {
                        Text(presentation.body).companionText(.code, theme: theme)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(theme.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                    }
                    if let tool = presentation.tool, item.request.title != "Allow \(tool)?" {
                        Text("Tool: " + tool).companionText(.supporting, theme: theme).textSelection(.enabled)
                    }
                    if let directory = presentation.directory {
                        Text(directory).companionText(.supporting, theme: theme).textSelection(.enabled)
                            .accessibilityLabel("Working directory: " + directory)
                    }
                }
            }
        }
    }

    private func respond(_ action: String) {
        guard inbox.isCurrent(item), phase == .active else { return }
        focusedQuestion = nil
        inbox.submit(item, action: action, answers: action == "answer" ? answers : [:])
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
            TaskCardActionLabel(title: title, theme: theme, primary: primary)
        }.buttonStyle(.plain)
    }
}
