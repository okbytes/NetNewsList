// NetNewsList extraction glue.
//
// Injected with Readability.js and DOMPurify into an isolated content world.
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
