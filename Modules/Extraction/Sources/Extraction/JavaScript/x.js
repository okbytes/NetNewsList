// NetNewsList extraction for X posts.
//
// Runs in the isolated content world of a live X page, after X's own scripts have
// rendered it. Finds the shared post among the posts X shows, adds the author's own
// posts right before and after it (a thread), and rebuilds them as plain HTML: text
// with its links and line breaks, photos at full size, video posters and quoted posts.
// The result is sanitized with DOMPurify like any other page.

"use strict";

const netNewsListX = (() => {

	function escapeHTML(string) {
		return string.replace(/[&<>"]/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;" }[character]));
	}

	function absoluteURL(href) {
		try {
			const url = new URL(href, location.href);
			return url.protocol === "http:" || url.protocol === "https:" ? url.href : null;
		} catch (e) {
			return null;
		}
	}

	// Elements matching `selector` that belong to `post` itself, not to a post quoted inside it.
	function own(post, selector) {
		return [...post.querySelectorAll(selector)].filter((element) => element.closest("article") === post);
	}

	// Every post element on the page, quoted posts aside. X puts a copy of the shared post
	// in the page header and the conversation (earlier posts, the shared post, replies)
	// in a list after it, which a signed-out page keeps hidden; both count.
	function postElements() {
		return [...document.querySelectorAll("article")].filter((article) => {
			return !(article.parentElement && article.parentElement.closest("article"));
		});
	}

	// The link to the post itself, which carries its timestamp: /<handle>/status/<id>.
	function statusLink(post) {
		for (const anchor of own(post, "a[href*='/status/']")) {
			const match = (anchor.getAttribute("href") || "").match(/^\/([A-Za-z0-9_]+)\/status\/(\d+)$/);
			if (match) {
				return { handle: match[1], id: match[2], anchor: anchor };
			}
		}
		return null;
	}

	// X prints times from an inline script next to the link: run("…", "format…", {"timestamp": ms, …}).
	function publishedTime(anchor) {
		const container = anchor.parentElement;
		const script = container && container.querySelector("script");
		const match = script && script.textContent.match(/"timestamp"\s*:\s*(\d+)/);
		return match ? new Date(Number(match[1])).toISOString() : null;
	}

	// The text of the first link to the author's profile that isn't the avatar or the @handle.
	function displayName(post, handle) {
		for (const anchor of own(post, "a")) {
			const text = anchor.textContent.trim();
			if (text && !text.startsWith("@") && (anchor.getAttribute("href") || "").toLowerCase() === `/${handle.toLowerCase()}`) {
				return text;
			}
		}
		return null;
	}

	// The post's text block: the first dir="auto" block that isn't part of a link (the name line).
	function textElement(post) {
		return own(post, "div[dir='auto']").find((element) => !element.closest("a")) || null;
	}

	// Text with its links, emoji (as their alt text) and line breaks, escaped for HTML.
	function inlineHTML(node) {
		let html = "";
		for (const child of node.childNodes) {
			if (child.nodeType === Node.TEXT_NODE) {
				html += escapeHTML(child.textContent);
			} else if (child.nodeType === Node.ELEMENT_NODE) {
				const tag = child.tagName;
				if (tag === "A") {
					const href = absoluteURL(child.getAttribute("href"));
					const text = escapeHTML(child.textContent);
					html += href ? `<a href="${escapeHTML(href)}">${text}</a>` : text;
				} else if (tag === "IMG") {
					html += escapeHTML(child.getAttribute("alt") || "");
				} else if (tag === "BR") {
					html += "\n";
				} else if (tag !== "SCRIPT" && tag !== "STYLE" && tag !== "svg") {
					html += inlineHTML(child);
				}
			}
		}
		return html;
	}

	function paragraphs(html) {
		return html.split(/\n\s*\n/)
			.map((paragraph) => paragraph.trim())
			.filter((paragraph) => paragraph.length > 0)
			.map((paragraph) => `<p>${paragraph.replace(/\n/g, "<br>")}</p>`)
			.join("\n");
	}

	function largeImageURL(src) {
		try {
			const url = new URL(src, location.href);
			url.searchParams.set("name", "large");
			return url.href;
		} catch (e) {
			return null;
		}
	}

	function parsePost(post) {
		const link = statusLink(post);
		if (!link) {
			return null;
		}
		const text = textElement(post);
		const photos = [];
		for (const image of own(post, "img[src*='pbs.twimg.com/media/']")) {
			const url = largeImageURL(image.getAttribute("src"));
			if (url && !photos.includes(url)) {
				photos.push(url);
			}
		}
		const videoPosters = [];
		for (const video of own(post, "video[poster]")) {
			const url = absoluteURL(video.getAttribute("poster"));
			if (url && !videoPosters.includes(url)) {
				videoPosters.push(url);
			}
		}
		const quoted = [...post.querySelectorAll("article")].find((article) => article.parentElement.closest("article") === post);
		return {
			element: post,
			id: link.id,
			handle: link.handle,
			name: displayName(post, link.handle),
			publishedTime: publishedTime(link.anchor),
			textHTML: text ? inlineHTML(text) : "",
			plainText: text ? text.textContent.trim() : "",
			lang: text ? text.getAttribute("lang") : null,
			photos: photos,
			videoPosters: videoPosters,
			quote: quoted ? parsePost(quoted) : null
		};
	}

	function postURL(post) {
		return `https://x.com/${post.handle}/status/${post.id}`;
	}

	function authorHTML(post) {
		const name = post.name ? `<strong>${escapeHTML(post.name)}</strong> ` : "";
		return `<p>${name}<a href="https://x.com/${escapeHTML(post.handle)}">@${escapeHTML(post.handle)}</a></p>`;
	}

	function postHTML(post) {
		let html = paragraphs(post.textHTML);
		for (const photo of post.photos) {
			html += `\n<p><img src="${escapeHTML(photo)}" alt=""></p>`;
		}
		for (const poster of post.videoPosters) {
			html += `\n<p><a href="${escapeHTML(postURL(post))}"><img src="${escapeHTML(poster)}" alt=""></a></p>`;
			html += `\n<p><a href="${escapeHTML(postURL(post))}">Watch the video on X</a></p>`;
		}
		if (post.quote) {
			html += `\n<blockquote>\n${authorHTML(post.quote)}\n${postHTML(post.quote)}\n<p><a href="${escapeHTML(postURL(post.quote))}">View the quoted post on X</a></p>\n</blockquote>`;
		}
		return html;
	}

	function titleText(post) {
		const firstLine = post.plainText.split("\n").map((line) => line.trim()).find((line) => line.length > 0) || "";
		const snippet = firstLine.length > 80 ? `${firstLine.slice(0, 79).trimEnd()}…` : firstLine;
		const author = post.name || `@${post.handle}`;
		return snippet ? `${author} on X: “${snippet}”` : `${author} on X`;
	}

	// An X Article (long-form post): its rich-text body, which X marks with this class.
	function articleBody(root) {
		return root.querySelector(".x-article-body");
	}

	// The Article's cover, title and body: its text blocks in order, with photos at full
	// size and any embedded posts X has rendered as quotes. Signed out, X leaves the
	// embedded posts out.
	function articleContent(root, author) {
		const body = articleBody(root);
		const titleElement = root.querySelector("h1");
		const cover = root.querySelector("img[alt='Article cover image']");

		// Posts embedded in `root`, not the ones quoted inside them.
		const embeddedPosts = (root) => [...root.querySelectorAll("article")].filter((article) => {
			const outer = article.parentElement.closest("article");
			return !outer || !root.contains(outer);
		});
		const embedded = embeddedPosts(body);
		const clone = body.cloneNode(true);
		embeddedPosts(clone).forEach((element, index) => {
			const post = parsePost(embedded[index]);
			const quote = document.createElement("div");
			quote.innerHTML = post ? `<blockquote>\n${authorHTML(post)}\n${postHTML(post)}\n<p><a href="${escapeHTML(postURL(post))}">View the post on X</a></p>\n</blockquote>` : "";
			element.replaceWith(quote);
		});
		for (const element of clone.querySelectorAll("style, script, template, button, svg")) {
			element.remove();
		}
		for (const image of clone.querySelectorAll("img")) {
			const url = largeImageURL(image.getAttribute("src") || "");
			image.removeAttribute("srcset");
			image.removeAttribute("sizes");
			if (url) {
				image.setAttribute("src", url);
			}
		}
		for (const anchor of clone.querySelectorAll("a[href]")) {
			const href = absoluteURL(anchor.getAttribute("href"));
			if (href) {
				anchor.setAttribute("href", href);
			} else {
				anchor.removeAttribute("href");
			}
		}

		const coverURL = cover ? largeImageURL(cover.getAttribute("src") || "") : null;
		const html = (coverURL ? `<p><img src="${escapeHTML(coverURL)}" alt=""></p>\n` : "") + clone.innerHTML;
		const content = DOMPurify.sanitize(html, {
			FORBID_TAGS: ["style", "form", "input", "button", "textarea", "select", "dialog"],
			FORBID_ATTR: ["style", "class", "target"]
		});
		const text = body.textContent.replace(/\s+/g, " ").trim();
		const title = titleElement ? titleElement.textContent.trim() : null;
		return {
			url: location.href,
			title: title || (author ? titleText(author) : null),
			byline: author ? (author.name ? `${author.name} (@${author.handle})` : `@${author.handle}`) : null,
			content: content,
			textLength: text.length,
			excerpt: text.slice(0, 200),
			siteName: "X",
			lang: body.getAttribute("lang") || null,
			publishedTime: author ? author.publishedTime : null,
			leadImage: coverURL
		};
	}

	// "post" once the shared post (or, without a post ID, an Article) has rendered,
	// "login" when X shows only its sign-in wall, "loading" otherwise.
	function state(statusID) {
		if (statusID ? postElements().some((post) => (statusLink(post) || {}).id === statusID) : articleBody(document)) {
			return "post";
		}
		const asksToSignIn = document.querySelector("a[href*='/i/flow/login'], a[href*='mode=login']");
		if (asksToSignIn && document.readyState === "complete" && postElements().length === 0) {
			return "login";
		}
		return "loading";
	}

	// The shared post and the author's posts around it, or the Article it carries, or
	// null when it isn't on the page. Without a post ID, the page's Article.
	function extract(statusID) {
		if (!statusID) {
			const body = articleBody(document);
			const authorElement = body && body.closest("article");
			return body ? articleContent(authorElement || document, authorElement ? parsePost(authorElement) : null) : null;
		}
		// The header copy of the shared post comes first; keeping each post's last
		// occurrence puts it back in its place in the conversation.
		const postsByID = new Map();
		for (const element of postElements()) {
			const post = parsePost(element);
			if (!post) {
				continue;
			}
			const copy = postsByID.get(post.id);
			if (copy) {
				post.name = post.name || copy.name;
				post.publishedTime = post.publishedTime || copy.publishedTime;
				if (copy.plainText.length > post.plainText.length) {
					post.textHTML = copy.textHTML;
					post.plainText = copy.plainText;
				}
				postsByID.delete(post.id);
			}
			postsByID.set(post.id, post);
		}
		const posts = [...postsByID.values()];
		const focalIndex = posts.findIndex((post) => post.id === statusID);
		if (focalIndex < 0) {
			return null;
		}
		const focal = posts[focalIndex];
		if (articleBody(focal.element)) {
			return articleContent(focal.element, focal);
		}
		const isByAuthor = (post) => post.handle.toLowerCase() === focal.handle.toLowerCase();
		let start = focalIndex;
		while (start > 0 && isByAuthor(posts[start - 1])) {
			start -= 1;
		}
		let end = focalIndex;
		while (end + 1 < posts.length && isByAuthor(posts[end + 1])) {
			end += 1;
		}
		const thread = posts.slice(start, end + 1);

		const html = thread.map(postHTML).join("\n");
		const content = DOMPurify.sanitize(html, {
			FORBID_TAGS: ["style", "form", "input", "button", "textarea", "select", "dialog"],
			FORBID_ATTR: ["style"]
		});
		const text = thread.map((post) => post.plainText).join("\n\n");
		const leadImage = thread.flatMap((post) => post.photos.concat(post.videoPosters))[0] || null;
		return {
			url: location.href,
			title: titleText(thread[0]),
			byline: focal.name ? `${focal.name} (@${focal.handle})` : `@${focal.handle}`,
			content: content,
			textLength: text.length,
			excerpt: text.slice(0, 200),
			siteName: "X",
			lang: focal.lang,
			publishedTime: thread[0].publishedTime,
			leadImage: leadImage
		};
	}

	return { state: state, extract: extract };
})();
