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

// Normalizes and sanitizes imported HTML (from Apple Notes, rich text, or an HTML file)
// without running scripts or loading external resources. Preserves semantic headings,
// emphasis, lists, links, tables, blockquotes, code blocks and images while stripping
// inline fonts/colors so NetNewsList's typography renders cleanly.
function netNewsListCleanImportedHTML(html) {
	const doc = new DOMParser().parseFromString(html, "text/html");
	const documentTitle = (doc.title || "").trim();
	const root = doc.body || doc.documentElement;
	if (!root) {
		return null;
	}

	root.querySelectorAll("script, style, noscript, meta, link, title").forEach(el => el.remove());

	// Preserve Apple Notes / rich-text inline styling semantics before DOMPurify strips style attributes.
	const isMonospace = family => /(?:^|[,\s"'])(?:sf\s*mono|menlo|monaco|consolas|courier|ui-monospace|monospace)(?:$|[,\s"'])/i.test(family || "");

	const parseFontSizePx = element => {
		const inline = element.getAttribute("style") || "";
		const pxMatch = inline.match(/font-size\s*:\s*([\d.]+)\s*(px|pt|em|rem)/i);
		if (pxMatch) {
			const value = parseFloat(pxMatch[1]);
			const unit = pxMatch[2].toLowerCase();
			if (unit === "px") { return value; }
			if (unit === "pt") { return value * (4 / 3); }
			if (unit === "em" || unit === "rem") { return value * 16; }
		}
		if (element.tagName === "FONT") {
			const sizeAttr = parseInt(element.getAttribute("size") || "", 10);
			const map = { 1: 10, 2: 13, 3: 16, 4: 18, 5: 24, 6: 32, 7: 48 };
			if (map[sizeAttr]) { return map[sizeAttr]; }
		}
		return null;
	};

	const isBoldStyle = element => {
		const inline = element.getAttribute("style") || "";
		const match = inline.match(/font-weight\s*:\s*([^;]+)/i);
		if (!match) { return false; }
		const val = match[1].trim().toLowerCase();
		if (val === "bold" || val === "bolder") { return true; }
		const num = parseInt(val, 10);
		return !isNaN(num) && num >= 600;
	};

	const isItalicStyle = element => {
		const inline = element.getAttribute("style") || "";
		return /font-style\s*:\s*(?:italic|oblique)/i.test(inline);
	};

	const isStrikeStyle = element => {
		const inline = element.getAttribute("style") || "";
		return /text-decoration(?:-line)?\s*:[^;]*line-through/i.test(inline);
	};

	const isMonoStyle = element => {
		const inline = element.getAttribute("style") || "";
		const match = inline.match(/font-family\s*:\s*([^;]+)/i);
		return match ? isMonospace(match[1]) : false;
	};

	// Promote Apple Notes heading divs (large font-size or <font size="5+">) into semantic headings.
	const blockSizes = [];
	root.querySelectorAll("div, p").forEach(block => {
		if (block.closest("li, blockquote, pre, table, h1, h2, h3, h4, h5, h6")) {
			return;
		}
		if (block.querySelector("div, p, ul, ol, table, blockquote, pre, h1, h2, h3, h4, h5, h6")) {
			return;
		}
		const text = (block.textContent || "").trim();
		if (!text) {
			return;
		}
		let size = parseFontSizePx(block);
		if (size === null) {
			const styled = block.querySelector("[style*='font-size'], font[size]");
			if (styled && (styled.textContent || "").trim() === text) {
				size = parseFontSizePx(styled);
			}
		}
		if (size !== null) {
			blockSizes.push({ block, size, text });
		}
	});

	// Compute the body font size weighted by character count (mode / weighted median),
	// so short notes with several headings don't skew the baseline size upward.
	let bodySize = 14;
	if (blockSizes.length >= 2) {
		const sizeWeights = new Map();
		for (const entry of blockSizes) {
			const rounded = Math.round(entry.size);
			sizeWeights.set(rounded, (sizeWeights.get(rounded) || 0) + entry.text.length);
		}
		let bestWeight = -1;
		for (const [size, weight] of sizeWeights.entries()) {
			if (weight > bestWeight || (weight === bestWeight && size < bodySize)) {
				bestWeight = weight;
				bodySize = size;
			}
		}
	}

	let promotedFirstHeading = false;
	for (const entry of blockSizes) {
		if (entry.text.length > 160) {
			continue;
		}
		let tag = null;
		if (entry.size >= Math.max(bodySize * 1.45, 20)) {
			tag = promotedFirstHeading ? "h2" : "h1";
			promotedFirstHeading = true;
		} else if (entry.size >= Math.max(bodySize * 1.18, 16)) {
			tag = "h2";
		}
		if (tag) {
			const heading = doc.createElement(tag);
			heading.textContent = entry.text;
			entry.block.replaceWith(heading);
		}
	}

	// Convert styled spans into semantic inline elements before style attributes are stripped.
	root.querySelectorAll("span[style], font").forEach(el => {
		if (el.closest("pre, code")) {
			return;
		}
		const bold = isBoldStyle(el);
		const italic = isItalicStyle(el);
		const strike = isStrikeStyle(el);
		const mono = isMonoStyle(el);
		if (!bold && !italic && !strike && !mono) {
			return;
		}
		let inner = doc.createDocumentFragment();
		while (el.firstChild) {
			inner.appendChild(el.firstChild);
		}
		const wrap = tagName => {
			const wrapper = doc.createElement(tagName);
			wrapper.appendChild(inner);
			inner = wrapper;
		};
		if (mono) { wrap("code"); }
		if (strike) { wrap("s"); }
		if (italic) { wrap("em"); }
		if (bold) { wrap("strong"); }
		el.replaceWith(inner);
	});

	// Convert Apple Notes' <tt> elements and standalone monospace blocks.
	root.querySelectorAll("tt").forEach(tt => {
		const code = doc.createElement("code");
		while (tt.firstChild) {
			code.appendChild(tt.firstChild);
		}
		tt.replaceWith(code);
	});

	// Collect consecutive pure-monospace divs into a <pre><code> block.
	const isMonospaceLineDiv = el => {
		if (!el || el.tagName !== "DIV") { return false; }
		const text = (el.textContent || "").trim();
		if (!text) { return false; }
		if (isMonoStyle(el)) { return true; }
		const codes = el.querySelectorAll("code");
		return codes.length > 0 && Array.from(codes).map(c => c.textContent).join("").trim() === text;
	};

	const topChildren = Array.from(root.children);
	for (let i = 0; i < topChildren.length; i++) {
		const child = topChildren[i];
		if (!child.parentNode || !isMonospaceLineDiv(child)) {
			continue;
		}
		const run = [child];
		let j = i + 1;
		while (j < topChildren.length && isMonospaceLineDiv(topChildren[j])) {
			run.push(topChildren[j]);
			j++;
		}
		if (run.length >= 2 || (run[0].textContent || "").includes("\n")) {
			const pre = doc.createElement("pre");
			const code = doc.createElement("code");
			code.textContent = run.map(el => el.textContent).join("\n");
			pre.appendChild(code);
			run[0].replaceWith(pre);
			for (let k = 1; k < run.length; k++) {
				run[k].remove();
			}
			i = j - 1;
		}
	}

	// Remove empty spacer divs (Apple Notes emits <div><br></div> between paragraphs)
	// and turn leaf <div> lines into <p> elements.
	root.querySelectorAll("div").forEach(div => {
		if (div.closest("pre, table")) {
			return;
		}
		const hasMedia = div.querySelector("img, svg, video, audio, iframe, hr, table");
		const hasBlocks = div.querySelector("div, p, h1, h2, h3, h4, h5, h6, ul, ol, blockquote, pre, table, figure");
		if (!hasMedia && !hasBlocks && !(div.textContent || "").trim()) {
			div.remove();
			return;
		}
		if (!hasBlocks) {
			const p = doc.createElement("p");
			while (div.firstChild) {
				p.appendChild(div.firstChild);
			}
			div.replaceWith(p);
		}
	});

	// Detect whether the document actually contains rich semantic formatting, vs raw plain text
	// (such as an Apple Note containing unrendered Markdown syntax).
	const hasFormatting = Boolean(root.querySelector("h1, h2, h3, h4, h5, h6, strong, b, em, i, u, s, del, ul, ol, li, blockquote, pre, code, table, a[href], img"));

	// Build plain text preserving paragraph breaks for fallback/Markdown detection and excerpt.
	const plainBlocks = [];
	const blockSelector = "h1, h2, h3, h4, h5, h6, p, li, pre, blockquote";
	const matchedBlocks = root.querySelectorAll(blockSelector);
	if (matchedBlocks.length > 0) {
		matchedBlocks.forEach(el => {
			if (el.parentElement && el.parentElement.closest(blockSelector)) {
				return;
			}
			const t = (el.textContent || "").trim();
			if (t) {
				plainBlocks.push(t);
			}
		});
	} else {
		const t = (root.textContent || "").trim();
		if (t) {
			plainBlocks.push(t);
		}
	}
	const plainText = plainBlocks.join("\n\n");

	// Extract a leading <h1> as the article title and remove it from the body so the title
	// doesn't appear twice (NetNewsList renders the title in its own <h1> header).
	let extractedTitle = null;
	const firstElement = root.firstElementChild;
	if (firstElement && firstElement.tagName === "H1") {
		const h1Text = (firstElement.textContent || "").trim();
		if (h1Text) {
			extractedTitle = h1Text;
			firstElement.remove();
		}
	}
	if (!extractedTitle && documentTitle) {
		extractedTitle = documentTitle;
	}

	const sanitized = DOMPurify.sanitize(root.innerHTML, {
		FORBID_TAGS: ["style", "script", "form", "input", "button", "textarea", "select", "dialog", "iframe", "font"],
		FORBID_ATTR: ["style", "class", "id"],
		ADD_DATA_URI_TAGS: ["img"]
	}).trim();

	// Compute a short plain-text excerpt from the remaining body.
	const excerptDoc = new DOMParser().parseFromString(sanitized, "text/html");
	const bodyText = ((excerptDoc.body && excerptDoc.body.textContent) || "").replace(/\s+/g, " ").trim();
	const excerpt = bodyText.length > 240 ? bodyText.slice(0, 240).trim() + "…" : (bodyText || null);

	return {
		title: extractedTitle,
		content: sanitized || null,
		plainText: plainText,
		excerpt: excerpt,
		hasFormatting: hasFormatting,
		textLength: bodyText.length
	};
}
