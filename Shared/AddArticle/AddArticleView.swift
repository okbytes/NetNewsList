//
//  AddArticleView.swift
//  NetNewsList
//
//  Saves a page to the reading list by URL. Shared by the Mac sheet and the iOS form sheet.
//

import SwiftUI
import Account

struct AddArticleView: View {

	@State private var urlString: String
	@State private var title: String
	@State private var isSaving = false
	@State private var errorMessage: String?
	@FocusState private var isURLFieldFocused: Bool

	private let dismiss: () -> Void

	init(initialURL: String? = nil, initialTitle: String? = nil, dismiss: @escaping () -> Void) {
		_urlString = State(initialValue: initialURL ?? "")
		_title = State(initialValue: initialTitle ?? "")
		self.dismiss = dismiss
	}

	var body: some View {
#if os(macOS)
		VStack(alignment: .leading, spacing: 16) {
			Text("Add Article")
				.font(.headline)
			fields
			HStack {
				Spacer()
				Button("Cancel", role: .cancel, action: dismiss)
					.keyboardShortcut(.cancelAction)
				Button("Save", action: save)
					.keyboardShortcut(.defaultAction)
					.disabled(!canSave)
			}
		}
		.padding(20)
		.frame(width: 440)
		.onAppear {
			isURLFieldFocused = true
		}
#else
		NavigationStack {
			Form {
				fields
			}
			.navigationTitle("Add Article")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel", role: .cancel, action: dismiss)
				}
				ToolbarItem(placement: .confirmationAction) {
					Button("Save", action: save)
						.disabled(!canSave)
				}
			}
			.onAppear {
				isURLFieldFocused = true
			}
		}
#endif
	}

	@ViewBuilder
	private var fields: some View {
		HStack {
			urlField
#if os(iOS)
			PasteButton(payloadType: URL.self) { urls in
				if let url = urls.first {
					urlString = url.absoluteString
				}
			}
			.labelStyle(.iconOnly)
#endif
		}
		.onSubmit(save)
		TextField("Title (optional)", text: $title)
		if let errorMessage {
			Text(errorMessage)
				.foregroundStyle(.red)
				.font(.callout)
		}
		if isSaving {
			ProgressView()
		}
	}

	private var urlField: some View {
		TextField("URL", text: $urlString, prompt: Text(verbatim: "https://"))
			.focused($isURLFieldFocused)
			.autocorrectionDisabled()
#if os(iOS)
			.keyboardType(.URL)
			.textInputAutocapitalization(.never)
			.submitLabel(.done)
#endif
	}

	private var canSave: Bool {
		!isSaving && !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
	}

	private func save() {
		guard canSave else {
			return
		}
		isSaving = true
		errorMessage = nil
		let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
		Task { @MainActor in
			do {
				try await AccountManager.shared.defaultAccount.saveArticle(url: urlString, title: trimmedTitle.isEmpty ? nil : trimmedTitle, content: nil)
				dismiss()
			} catch {
				errorMessage = error.localizedDescription
				isSaving = false
			}
		}
	}
}
