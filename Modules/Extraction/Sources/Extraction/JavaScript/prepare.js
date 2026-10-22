// NetNewsList's changes to a page before Readability reads it. Shared by the app's
// extraction (extract.js) and Safari's share capture (SafariExt.js, which
// buildscripts/make_safari_ext_js.sh builds from these files).

"use strict";

// Readability marks down blocks whose class names sound hidden or scrolling ("hidden",
// "scroll"), and drops them when they have few commas, as code blocks do. Tailwind's layout
// utilities (overflow-hidden, scroll-mt-24) match by accident, so code blocks and figures
// wrapped in them went missing. They only set layout, so remove them first.
function netNewsListRemoveLayoutClasses(doc) {
	for (const element of doc.querySelectorAll("[class*='overflow-'], [class*='scroll']")) {
		const names = [...element.classList];
		const kept = names.filter(name => !/(?:^|:)!?-?(?:overflow|overscroll|scroll|scrollbar)-[^:]*$/.test(name));
		if (kept.length < names.length) {
			element.setAttribute("class", kept.join(" "));
		}
	}
}

// Tweets embedded with react-tweet, common on Next.js sites, are built from class names that
// Readability takes for page furniture (header, meta, media), so it kept the avatar and the
// text and dropped the author, the photos and the link. Rebuild each as the quote X's own
// embed code makes, with one short link, so Readability doesn't drop it as a list of links.
function netNewsListRebuildEmbeddedTweets(doc) {
	for (const tweet of doc.querySelectorAll(".react-tweet-theme")) {
		const link = tweet.querySelector("a[href*='/status/']");
		const text = tweet.querySelector("p[lang]");
		if (!link || !text) {
			continue;
		}
		const paragraph = (...nodes) => {
			const p = doc.createElement("p");
			p.append(...nodes);
			return p;
		};
		const image = src => {
			const img = doc.createElement("img");
			img.setAttribute("src", src);
			img.setAttribute("alt", "");
			return img;
		};

		const quote = doc.createElement("blockquote");
		quote.append(paragraph(...text.cloneNode(true).childNodes));
		for (const img of tweet.querySelectorAll("img[src*='pbs.twimg.com/media/']")) {
			const url = new URL(img.getAttribute("src"), doc.baseURI);
			url.searchParams.set("name", "large");
			quote.append(paragraph(image(url.href)));
		}
		for (const video of tweet.querySelectorAll("video[poster]")) {
			quote.append(paragraph(image(video.getAttribute("poster"))));
		}

		// "— Name (@handle) <a>May 3, 2026</a>"
		const name = tweet.querySelector("span[title]:not([title^='@'])");
		const handle = tweet.querySelector("span[title^='@']");
		const author = [name && name.title, handle && `(${handle.title})`].filter(Boolean).join(" ");
		const datetime = tweet.querySelector("time[datetime]");
		const date = datetime && new Date(datetime.getAttribute("datetime"));
		const permalink = doc.createElement("a");
		permalink.setAttribute("href", link.href);
		permalink.textContent = date && !isNaN(date) ? date.toLocaleDateString("en-US", { month: "long", day: "numeric", year: "numeric", timeZone: "UTC" }) : "View on X";
		quote.append(paragraph(author ? `— ${author} ` : "", permalink));
		tweet.replaceWith(quote);
	}
}

// Highlighters that put each line of code in a <div> lose their blank lines to Readability,
// which removes empty <div>s, and get each line wrapped in a paragraph, so code came out
// double-spaced. Join the lines with line breaks first. (main.js does the same for pages
// saved before this.)
function netNewsListJoinCodeLines(doc) {
	for (const pre of doc.querySelectorAll("pre")) {
		const container = pre.querySelector(":scope > code") || pre;
		const lines = [...container.children].filter(child => child.matches("div, p"));
		if (lines.length === 0) {
			continue;
		}
		for (const node of [...container.childNodes]) {
			if (node.nodeType === Node.TEXT_NODE && !node.textContent.trim()) {
				node.remove();
			}
		}
		lines.forEach((line, index) => {
			line.querySelectorAll("div, p").forEach(block => block.replaceWith(...block.childNodes));
			// Some highlighters put a line break in empty lines already.
			line.replaceWith(...line.childNodes, index < lines.length - 1 && !line.textContent.endsWith("\n") ? "\n" : "");
		});
	}
}

function netNewsListPrepareDocument(doc) {
	netNewsListRemoveLayoutClasses(doc);
	netNewsListRebuildEmbeddedTweets(doc);
	netNewsListJoinCodeLines(doc);
}
