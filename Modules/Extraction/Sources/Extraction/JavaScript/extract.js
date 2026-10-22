// NetNewsList extraction glue.
//
// Injected with Readability.js, DOMPurify and prepare.js into an isolated content world.
// The page HTML is parsed into an inert document with DOMParser, so the page's
// own scripts never run and its images, styles and frames are never loaded.

"use strict";

function netNewsListMetaContent(doc, selectors) {
	for (const selector of selectors) {
		const element = doc.querySelector(selector);
		if (!element) {
			continue;
		}
		const value = (element.getAttribute("content") || element.getAttribute("href") || "").trim();
		if (value.length > 0) {
			return value;
		}
	}
	return null;
}

function netNewsListAbsoluteURL(value, baseURL) {
	if (!value) {
		return null;
	}
	try {
		const url = new URL(value, baseURL);
		if (url.protocol === "http:" || url.protocol === "https:") {
			return url.href;
		}
	} catch (e) {
	}
	return null;
}

// React streams the parts of a page that weren't ready at first (code samples, figures) to
// the end of the HTML in hidden <div id="S:n">s, each followed by a script ($RC, $RR or $RS)
// that moves it into the placeholder it fills. The page's scripts never run here, so make
// the same moves, in the order the scripts would have. The calls are read from the HTML,
// since DOMParser leaves <script>s out when scripts are off. Only parts worth reading come
// in: code, images, video, tables or prose, and nothing with form fields or a tree, grid or
// slider. An interactive demo needs its scripts, and its labels and counters read as noise.
function netNewsListRevealStreamedContent(doc, html) {
	const app = "input, select, textarea, [role='tree'], [role='treegrid'], [role='grid'], [role='listbox'], [role='slider'], [role='spinbutton'], [role='toolbar']";
	const isWorthReading = element => !element.querySelector(app)
		&& (element.querySelector("pre, img, picture, video, table") || [...element.querySelectorAll("p")].some(p => p.textContent.trim().length >= 80));
	for (const [, instruction, firstID, secondID] of html.matchAll(/\$(RC|RR|RS)\("([^"]+)","([^"]+)"/g)) {
		if (instruction === "RS") {
			// $RS("S:n", "P:n"): the segment's children replace its <template id="P:n">.
			const segment = doc.getElementById(firstID);
			const placeholder = doc.getElementById(secondID);
			if (!segment || !placeholder || !isWorthReading(segment)) {
				continue;
			}
			placeholder.replaceWith(...segment.childNodes);
			segment.remove();
			continue;
		}
		// $RC("B:n", "S:n"): a boundary is <!--$?--><template id="B:n">…fallback…<!--/$-->,
		// and the segment's children replace everything between the two comments.
		const template = doc.getElementById(firstID);
		const content = doc.getElementById(secondID);
		const start = template && template.previousSibling;
		if (!content || !start || start.nodeType !== Node.COMMENT_NODE || !isWorthReading(content)) {
			continue;
		}
		let node = start.nextSibling;
		let depth = 0;
		while (node) {
			if (node.nodeType === Node.COMMENT_NODE) {
				if (node.data === "/$") {
					if (depth === 0) {
						break;
					}
					depth--;
				} else if (["$", "$?", "$!"].includes(node.data)) {
					depth++;
				}
			}
			const next = node.nextSibling;
			node.remove();
			node = next;
		}
		if (!node) {
			continue;
		}
		node.before(...content.childNodes);
		content.remove();
		start.data = "$";
	}
}

function netNewsListExtract(html, pageURL) {
	const doc = new DOMParser().parseFromString(html, "text/html");

	// Resolve relative URLs against the page, including a relative <base href>.
	let base = doc.querySelector("base[href]");
	if (base) {
		const resolved = netNewsListAbsoluteURL(base.getAttribute("href"), pageURL);
		base.setAttribute("href", resolved || pageURL);
	} else {
		base = doc.createElement("base");
		base.setAttribute("href", pageURL);
		(doc.head || doc.documentElement).prepend(base);
	}
	const baseURL = doc.baseURI || pageURL;

	netNewsListRevealStreamedContent(doc, html);
	netNewsListPrepareDocument(doc);

	// Readability changes the document, so read metadata first.
	const documentTitle = (doc.title || "").trim();
	const leadImage = netNewsListAbsoluteURL(netNewsListMetaContent(doc, [
		"meta[property='og:image:secure_url']",
		"meta[property='og:image']",
		"meta[name='twitter:image']",
		"meta[name='twitter:image:src']",
		"link[rel='image_src']"
	]), baseURL);

	let article = null;
	try {
		article = new Readability(doc).parse();
	} catch (e) {
		article = null;
	}

	let content = null;
	let textLength = 0;
	if (article && article.content) {
		content = DOMPurify.sanitize(article.content, {
			FORBID_TAGS: ["style", "form", "input", "button", "textarea", "select", "dialog"],
			FORBID_ATTR: ["style"]
		});
		textLength = article.length || 0;
	}

	return {
		url: pageURL,
		title: (article && article.title) || documentTitle || null,
		byline: (article && article.byline) || null,
		content: content,
		textLength: textLength,
		excerpt: (article && article.excerpt) || null,
		siteName: (article && article.siteName) || null,
		lang: (article && article.lang) || null,
		publishedTime: (article && article.publishedTime) || null,
		leadImage: leadImage
	};
}
