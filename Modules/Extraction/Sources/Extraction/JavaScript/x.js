// NetNewsList extraction for X posts.
//
// Runs in the isolated content world of a live X page, signed out, after X's own
// scripts have rendered it. Finds the shared post among the posts X shows, adds the
// author's own posts right before and after it (a thread), and rebuilds them as plain
// HTML: text with its links and line breaks, photos at full size, video posters and
// quoted posts. The result is sanitized with DOMPurify like any other page.

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

	// What X wraps each post quoted in `post` in: the quoted post's <article>, inside a frame
	// that links to it with a link of its own.
	function quoteFrames(post) {
		return [...post.querySelectorAll("article")].map((quoted) => {
			const frame = quoted.parentElement.closest("[role='link']");
			return frame && frame !== post && post.contains(frame) ? frame : quoted;
		});
	}

	// Elements matching `selector` that belong to `post` itself, not to a post quoted inside it.
	function own(post, selector) {
		const frames = quoteFrames(post);
		return [...post.querySelectorAll(selector)].filter((element) => !frames.some((frame) => frame.contains(element)));
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
	// Without one (the shared post at the top of the page has none), the time is in the post ID:
	// since late 2010 an ID is the milliseconds since X's epoch, shifted left 22 bits.
	function publishedTime(anchor, id) {
		const container = anchor.parentElement;
		const script = container && container.querySelector("script");
		const match = script && script.textContent.match(/"timestamp"\s*:\s*(\d+)/);
		if (match) {
			return new Date(Number(match[1])).toISOString();
		}
		const snowflake = BigInt(id);
		return snowflake > 10n ** 12n ? new Date(Number(snowflake >> 22n) + 1288834974657).toISOString() : null;
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
				} else if (tag !== "SCRIPT" && tag !== "STYLE" && tag !== "BUTTON" && tag !== "svg") {
					html += inlineHTML(child);
				}
			}
		}
		return html;
	}

	// The text without X's "Show more" button, which a cut-off post has at the end of it.
	function plainText(node) {
		const clone = node.cloneNode(true);
		for (const button of clone.querySelectorAll("button")) {
			button.remove();
		}
		return clone.textContent.trim();
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
		const videoPosters = [];
		for (const video of own(post, "video[poster]")) {
			const poster = absoluteURL(video.getAttribute("poster"));
			const url = poster && poster.startsWith("https://pbs.twimg.com/") ? largeImageURL(poster) : poster;
			if (url && !videoPosters.includes(url)) {
				videoPosters.push(url);
			}
		}
		// X also shows a video's poster as an image of the post; it comes once, as the video's.
		const posterPaths = videoPosters.map((url) => new URL(url).pathname);
		const photos = [];
		for (const image of own(post, "img[src*='pbs.twimg.com/media/']")) {
			const url = largeImageURL(image.getAttribute("src"));
			if (url && !photos.includes(url) && !posterPaths.includes(new URL(url).pathname)) {
				photos.push(url);
			}
		}
		const quoted = [...post.querySelectorAll("article")].find((article) => article.parentElement.closest("article") === post);
		return {
			element: post,
			id: link.id,
			handle: link.handle,
			name: displayName(post, link.handle),
			publishedTime: publishedTime(link.anchor, link.id),
			textHTML: text ? inlineHTML(text) : "",
			plainText: text ? plainText(text) : "",
			lang: text ? text.getAttribute("lang") : null,
			isTruncated: text ? text.querySelector("button") !== null : false,
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

	// A cut-off post already ends with a link to the post.
	function quoteHTML(post, label) {
		const link = post.isTruncated ? "" : `\n<p><a href="${escapeHTML(postURL(post))}">${label}</a></p>`;
		return `<blockquote>\n${authorHTML(post)}\n${postHTML(post)}${link}\n</blockquote>`;
	}

	function postHTML(post) {
		let html = paragraphs(post.textHTML);
		if (post.isTruncated) {
			html += `\n<p><a href="${escapeHTML(postURL(post))}">Read the rest on X</a></p>`;
		}
		for (const photo of post.photos) {
			html += `\n<p><img src="${escapeHTML(photo)}" alt=""></p>`;
		}
		for (const poster of post.videoPosters) {
			html += `\n<p><a href="${escapeHTML(postURL(post))}"><img src="${escapeHTML(poster)}" alt=""></a></p>`;
			html += `\n<p><a href="${escapeHTML(postURL(post))}">Watch the video on X</a></p>`;
		}
		if (post.quote) {
			html += `\n${quoteHTML(post.quote, "View the quoted post on X")}`;
		}
		return html;
	}

	function sanitized(html) {
		return DOMPurify.sanitize(html, {
			FORBID_TAGS: ["style", "form", "input", "button", "textarea", "select", "dialog"],
			FORBID_ATTR: ["style", "class", "target"],
			ALLOW_DATA_ATTR: false
		});
	}

	// The shared post and the author's posts right before and after it.
	function threadAround(posts, statusID) {
		const focalIndex = posts.findIndex((post) => post.id === statusID);
		if (focalIndex < 0) {
			return null;
		}
		const focal = posts[focalIndex];
		const isByAuthor = (post) => post.handle.toLowerCase() === focal.handle.toLowerCase();
		let start = focalIndex;
		while (start > 0 && isByAuthor(posts[start - 1])) {
			start -= 1;
		}
		let end = focalIndex;
		while (end + 1 < posts.length && isByAuthor(posts[end + 1])) {
			end += 1;
		}
		return { focal: focal, posts: posts.slice(start, end + 1) };
	}

	function threadResult(thread) {
		const text = thread.posts.map((post) => post.plainText).join("\n\n");
		const focal = thread.focal;
		return {
			url: location.href,
			title: titleText(thread.posts[0]),
			byline: focal.name ? `${focal.name} (@${focal.handle})` : `@${focal.handle}`,
			content: sanitized(thread.posts.map(postHTML).join("\n")),
			textLength: text.length,
			excerpt: text.slice(0, 200),
			siteName: "X",
			lang: focal.lang,
			publishedTime: thread.posts[0].publishedTime,
			leadImage: thread.posts.flatMap((post) => post.photos.concat(post.videoPosters))[0] || null
		};
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
			quote.innerHTML = post ? quoteHTML(post, "View the post on X") : "";
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
		const content = sanitized(html);
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

	// Changes while X is still adding posts or an Article's embedded posts; the app waits
	// for it to settle before extracting.
	function signature() {
		const root = document.querySelector("main") || document.body;
		return `${document.querySelectorAll("article").length}:${root.textContent.length}`;
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
					post.isTruncated = copy.isTruncated;
				}
				postsByID.delete(post.id);
			}
			postsByID.set(post.id, post);
		}
		const thread = threadAround([...postsByID.values()], statusID);
		if (!thread) {
			return null;
		}
		if (articleBody(thread.focal.element)) {
			return articleContent(thread.focal.element, thread.focal);
		}
		return threadResult(thread);
	}

	return { state: state, signature: signature, extract: extract };
})();
