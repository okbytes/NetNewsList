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
			isTruncated: false,
			photos: photos,
			videoPosters: videoPosters,
			quote: quoted ? parsePost(quoted) : null
		};
	}

	// The post's address, or its author's when the post ID isn't on the page (a quoted post, signed in).
	function postURL(post) {
		return post.id ? `https://x.com/${post.handle}/status/${post.id}` : `https://x.com/${post.handle}`;
	}

	function authorHTML(post) {
		const name = post.name ? `<strong>${escapeHTML(post.name)}</strong> ` : "";
		return `<p>${name}<a href="https://x.com/${escapeHTML(post.handle)}">@${escapeHTML(post.handle)}</a></p>`;
	}

	function quoteHTML(post, label) {
		return `<blockquote>\n${authorHTML(post)}\n${postHTML(post)}\n<p><a href="${escapeHTML(postURL(post))}">${label}</a></p>\n</blockquote>`;
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
			html += `\n${quoteHTML(post.quote, post.quote.id ? "View the quoted post on X" : "View the author on X")}`;
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

	// MARK: X's classic client
	//
	// Signed-in people get X's older web client, which marks posts with data-testid: a
	// post is article[data-testid="tweet"], its text [data-testid="tweetText"], its author
	// [data-testid="User-Name"], its photos [data-testid="tweetPhoto"], its time a
	// time[datetime] inside the link to the post; a quoted post is a div[role="link"]
	// inside it. Articles are article[data-testid="twitterArticleReadView"].

	function isClassicPage() {
		return document.querySelector("article[data-testid='tweet'], article[data-testid='twitterArticleReadView'], [data-testid='primaryColumn']") !== null;
	}

	function classicPostOf(element) {
		return element.closest("article[data-testid='tweet']");
	}

	function classicQuoteContainers(post) {
		return [...post.querySelectorAll("div[role='link']")].filter((container) => {
			return classicPostOf(container) === post && container.querySelector("[data-testid='User-Name']") !== null;
		});
	}

	// Elements matching `selector` that belong to `post` itself, not to a post it quotes or embeds.
	function classicOwn(post, selector) {
		const quotes = classicQuoteContainers(post);
		return [...post.querySelectorAll(selector)].filter((element) => {
			return classicPostOf(element) === post && !quotes.some((quote) => quote.contains(element));
		});
	}

	function classicAuthor(container) {
		const userName = container.querySelector("[data-testid='User-Name']");
		if (!userName) {
			return null;
		}
		const handle = (userName.textContent.match(/@([A-Za-z0-9_]{1,15})/) || [])[1];
		if (!handle) {
			return null;
		}
		const lines = (userName.innerText || "").split("\n").map((line) => line.trim()).filter((line) => line.length > 0);
		const name = lines.length > 0 && !lines[0].startsWith("@") ? lines[0] : null;
		return { handle: handle, name: name };
	}

	function classicPhotos(elements) {
		const photos = [];
		for (const image of elements) {
			const url = largeImageURL(image.getAttribute("src") || "");
			if (url && /pbs\.twimg\.com\/media\//.test(url) && !photos.includes(url)) {
				photos.push(url);
			}
		}
		return photos;
	}

	function classicVideoPosters(elements) {
		const posters = [];
		for (const video of elements) {
			const url = absoluteURL(video.getAttribute("poster") || "");
			if (url && !posters.includes(url)) {
				posters.push(url);
			}
		}
		return posters;
	}

	function classicParsePost(post) {
		let link = null;
		for (const time of classicOwn(post, "time[datetime]")) {
			const anchor = time.closest("a[href*='/status/']");
			const match = anchor && (anchor.getAttribute("href") || "").match(/^\/([A-Za-z0-9_]+)\/status\/(\d+)/);
			if (match) {
				link = { handle: match[1], id: match[2], publishedTime: time.getAttribute("datetime") };
				break;
			}
		}
		if (!link) {
			return null;
		}
		const author = classicAuthor(post) || { handle: link.handle, name: null };
		const text = classicOwn(post, "[data-testid='tweetText']")[0];
		const quoteContainer = classicQuoteContainers(post)[0];
		return {
			element: post,
			id: link.id,
			handle: link.handle,
			name: author.name,
			publishedTime: link.publishedTime,
			textHTML: text ? inlineHTML(text) : "",
			plainText: text ? text.textContent.trim() : "",
			lang: text ? text.getAttribute("lang") : null,
			isTruncated: classicOwn(post, "[data-testid='tweet-text-show-more-link']").length > 0,
			photos: classicPhotos(classicOwn(post, "[data-testid='tweetPhoto'] img")),
			videoPosters: classicVideoPosters(classicOwn(post, "video[poster]")),
			quote: quoteContainer ? classicParseQuote(quoteContainer) : null
		};
	}

	function classicParseQuote(container) {
		const author = classicAuthor(container);
		if (!author) {
			return null;
		}
		const text = container.querySelector("[data-testid='tweetText']");
		const time = container.querySelector("time[datetime]");
		const anchor = container.querySelector("a[href*='/status/']");
		const id = anchor ? ((anchor.getAttribute("href") || "").match(/\/status\/(\d+)/) || [])[1] : null;
		return {
			id: id || null,
			handle: author.handle,
			name: author.name,
			publishedTime: time ? time.getAttribute("datetime") : null,
			textHTML: text ? inlineHTML(text) : "",
			plainText: text ? text.textContent.trim() : "",
			lang: text ? text.getAttribute("lang") : null,
			isTruncated: false,
			photos: classicPhotos(container.querySelectorAll("[data-testid='tweetPhoto'] img")),
			videoPosters: classicVideoPosters(container.querySelectorAll("video[poster]")),
			quote: null
		};
	}

	// The conversation's posts in reading order. X lays its list out with transforms, so
	// order by position rather than by place in the document.
	function classicPosts(root) {
		const elements = [...root.querySelectorAll("article[data-testid='tweet']")].filter((post) => {
			const outer = post.parentElement && classicPostOf(post.parentElement);
			return !outer || !root.contains(outer);
		});
		elements.sort((a, b) => a.getBoundingClientRect().top - b.getBoundingClientRect().top);
		const posts = [];
		for (const element of elements) {
			const post = classicParsePost(element);
			if (post && !posts.some((existing) => existing.id === post.id)) {
				posts.push(post);
			}
		}
		return posts;
	}

	// An Article's rich text, block by block: Draft.js blocks become paragraphs, headings and
	// lists stay, photos come at full size, embedded posts become quotes.
	function classicRichTextHTML(node) {
		let html = "";
		for (const child of node.children) {
			const tag = child.tagName;
			if (child.matches("article[data-testid='tweet']")) {
				const post = classicParsePost(child);
				html += post ? `\n${quoteHTML(post, "View the post on X")}` : "";
			} else if (/^H[1-6]$/.test(tag)) {
				html += `\n<${tag.toLowerCase()}>${inlineHTML(child).trim()}</${tag.toLowerCase()}>`;
			} else if (tag === "UL" || tag === "OL") {
				const items = [...child.children].map((item) => `<li>${inlineHTML(item).trim()}</li>`).join("");
				html += `\n<${tag.toLowerCase()}>${items}</${tag.toLowerCase()}>`;
			} else if (tag === "BLOCKQUOTE") {
				html += `\n<blockquote><p>${inlineHTML(child).trim()}</p></blockquote>`;
			} else if (tag === "IMG") {
				const url = largeImageURL(child.getAttribute("src") || "");
				html += url && /pbs\.twimg\.com\/media\//.test(url) ? `\n<p><img src="${escapeHTML(url)}" alt=""></p>` : "";
			} else if (child.matches("[data-block='true'], .public-DraftStyleDefault-block, [class*='longform-unstyled']") && !child.querySelector("article, h1, h2, h3, h4, ul, ol, blockquote, img, [data-block='true']")) {
				const text = inlineHTML(child).trim();
				html += text ? `\n<p>${text.replace(/\n/g, "<br>")}</p>` : "";
			} else {
				html += classicRichTextHTML(child);
			}
		}
		return html;
	}

	function classicArticleContent(readView, author) {
		const titleElement = readView.querySelector("[data-testid='twitter-article-title']");
		const richText = readView.querySelector("[data-testid='longformRichTextComponent']") || readView.querySelector("[data-testid='twitterArticleRichTextView']");
		if (!richText) {
			return null;
		}
		const cover = [...readView.querySelectorAll("[data-testid='tweetPhoto'] img")].find((image) => !richText.contains(image));
		const coverURL = cover ? largeImageURL(cover.getAttribute("src") || "") : null;
		const html = (coverURL ? `<p><img src="${escapeHTML(coverURL)}" alt=""></p>` : "") + classicRichTextHTML(richText);
		const text = richText.textContent.replace(/\s+/g, " ").trim();
		const title = titleElement ? titleElement.textContent.trim() : null;
		return {
			url: location.href,
			title: title || (author ? titleText(author) : null),
			byline: author ? (author.name ? `${author.name} (@${author.handle})` : `@${author.handle}`) : null,
			content: sanitized(html),
			textLength: text.length,
			excerpt: text.slice(0, 200),
			siteName: "X",
			lang: null,
			publishedTime: author ? author.publishedTime : null,
			leadImage: coverURL
		};
	}

	function classicFocalPost(statusID) {
		return classicPosts(document).find((post) => post.id === statusID) || null;
	}

	function classicExtract(statusID) {
		if (!statusID) {
			const readView = document.querySelector("article[data-testid='twitterArticleReadView']");
			const host = readView && classicPostOf(readView);
			return readView ? classicArticleContent(readView, host ? classicParsePost(host) : null) : null;
		}
		const posts = classicPosts(document);
		const thread = threadAround(posts, statusID);
		if (!thread) {
			return null;
		}
		const readView = thread.focal.element.querySelector("article[data-testid='twitterArticleReadView']");
		if (readView) {
			return classicArticleContent(readView, thread.focal);
		}
		return threadResult(thread);
	}

	// MARK: X's newer client (signed out)

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
		if (isClassicPage()) {
			const found = statusID ? classicFocalPost(statusID) : document.querySelector("article[data-testid='twitterArticleReadView']");
			return found ? "post" : "loading";
		}
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
		const root = document.querySelector("[data-testid='primaryColumn']") || document.querySelector("main") || document.body;
		return `${document.querySelectorAll("article").length}:${root.textContent.length}`;
	}

	// The shared post and the author's posts around it, or the Article it carries, or
	// null when it isn't on the page. Without a post ID, the page's Article.
	function extract(statusID) {
		if (isClassicPage()) {
			return classicExtract(statusID);
		}
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
