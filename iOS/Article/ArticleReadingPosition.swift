import Foundation

/// Device-local bookmarks, independent of Queue/Archive and CloudKit.
@MainActor enum ArticleReadingPosition {
	private static let prefix = "articleReadingPosition."
	// Invalidate captures still in flight when an article is deleted or reset to the top.
	private static var revisions = [String: Int]()

	static func revision(articleID: String) -> Int {
		revisions[articleID, default: 0]
	}

	static func save(_ position: [String: Any], articleID: String) {
		UserDefaults.standard.set(position, forKey: prefix + articleID)
	}

	static func remove(articleID: String) {
		revisions[articleID, default: 0] += 1
		UserDefaults.standard.removeObject(forKey: prefix + articleID)
	}

	static func script(articleID: String) -> String {
		var position = UserDefaults.standard.dictionary(forKey: prefix + articleID) ?? [:]
		position["articleID"] = articleID
		position["revision"] = revision(articleID: articleID)
		let data = try? JSONSerialization.data(withJSONObject: position)
		let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
		return """
		(() => {
		    const saved = \(json);
		    const body = document.getElementById('bodyContainer');
		    if (!body) return;
		    const blocks = Array.from(body.querySelectorAll('p, h1, h2, h3, h4, h5, h6, pre, li, blockquote, figure'))
		        .filter(el => el.getBoundingClientRect().height > 0);
		    const quote = el => el.textContent.trim().replace(/\\s+/g, ' ').slice(0, 160);
		    let reading = false;
		    let observer;
		    let frame;
		    const stopRestoring = () => {
		        reading = true;
		        observer?.disconnect();
		        cancelAnimationFrame(frame);
		    };
		    for (const event of ['touchstart', 'pointerdown', 'wheel', 'keydown']) {
		        window.addEventListener(event, stopRestoring, {once: true, passive: true});
		    }
		    const restore = () => {
		        if (reading || saved.index === undefined) return;
		        if (saved.top) { window.scrollTo(0, 0); return; }
		        let block = blocks[saved.index];
		        if (!block || quote(block) !== saved.quote) {
		            block = blocks.find(el => quote(el) === saved.quote);
		        }
		        // Re-extraction can replace the text. Don't guess a different passage.
		        if (!block) return;
		        const rect = block.getBoundingClientRect();
		        window.scrollTo(0, window.scrollY + rect.top + rect.height * saved.fraction);
		    };
		    observer = new ResizeObserver(() => {
		        cancelAnimationFrame(frame);
		        frame = requestAnimationFrame(restore);
		    });
		    observer.observe(document.body);
		    document.fonts.ready.then(restore);
		    restore();
		    window.nnlReadingPosition = () => {
		        if (!reading || !blocks.length) return null;
		        const top = window.scrollY <= 1;
		        let index = blocks.findIndex(el => el.getBoundingClientRect().bottom > 0);
		        if (index < 0) index = blocks.length - 1;
		        const rect = blocks[index].getBoundingClientRect();
		        return {articleID: saved.articleID, revision: saved.revision, index, quote: quote(blocks[index]), top,
		            fraction: Math.max(0, Math.min(1, -rect.top / rect.height))};
		    };
		    window.nnlBeginReading = stopRestoring;
		    window.nnlBackToTop = revision => {
		        saved.revision = revision;
		        stopRestoring();
		        window.scrollTo(0, 0);
		    };
		})();
		"""
	}
}
