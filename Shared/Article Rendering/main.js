// Here we are making iframes responsive.  Particularly useful for inline Youtube videos.
function wrapFrames() {
	document.querySelectorAll("iframe").forEach(element => {
		if (getComputedStyle(element).display === "none") {
			return;
		}
		if (parseInt(element.height) > 0) {
			preserveAspectRatioOfFixedSizeFrame(element);
			return;
		}
		var wrapper = document.createElement("div");
		wrapper.classList.add("iframeWrap");
		element.parentNode.insertBefore(wrapper, element);
		wrapper.appendChild(element);
	});
}

// The stylesheet clamps iframes to the article width with max-width: 100%,
// which leaves an attribute-sized iframe with its full height — distorted,
// and a huge blank box when the embed fails to load. Let the height follow
// the width instead.
function preserveAspectRatioOfFixedSizeFrame(element) {
	const numeric = /^[1-9]\d*$/;
	const width = element.getAttribute("width");
	const height = element.getAttribute("height");
	if (!numeric.test(width) || !numeric.test(height) || element.style.height) {
		return;
	}
	element.style.aspectRatio = width + " / " + height;
	element.style.height = "auto";
}

// Strip out color and font styling

function stripStylesFromElement(element, propertiesToStrip) {
	for (name of propertiesToStrip) {
		element.style.removeProperty(name);
	}
}

// Strip inline styles that could harm readability.
function stripStyles() {
	document.getElementsByTagName("body")[0].querySelectorAll("style, link[rel=stylesheet]").forEach(element => element.remove());
	// Removing "background" and "font" will also remove properties that would be reflected in them, e.g., "background-color" and "font-family"
	// The stylesheet forces images to height: auto, so an author aspect-ratio box can't be filled by its image — content after the box overlaps the overflowing image.
	document.getElementsByTagName("body")[0].querySelectorAll("[style]").forEach(element => stripStylesFromElement(element, ["color", "background", "font", "max-width", "max-height", "position", "aspect-ratio"]));
}

// Constrain the height of iframes whose heights are defined relative to the document body to be at most
// 50% of the viewport width.
function constrainBodyRelativeIframes() {
	let iframes = document.getElementsByTagName("iframe");

	for (iframe of iframes) {
		// The article body container is positioned, so it — not document.body —
		// is the offsetParent for iframes with no positioned ancestor in the content.
		const offsetParent = iframe.offsetParent;
		if (offsetParent === document.body || (offsetParent && (offsetParent.classList.contains("articleBody") || offsetParent.classList.contains("article-body")))) {
			let heightAttribute = iframe.style.height;

			if (/%|vw|vh$/i.test(heightAttribute)) {
				iframe.classList.add("nnw-constrained");
			}
		}
	}
}

// Convert all Feedbin proxy images to be used as src, otherwise change image locations to be absolute if not already
function convertImgSrc() {
	document.querySelectorAll("img").forEach(element => {
		if (element.hasAttribute("data-canonical-src")) {
			element.src = element.getAttribute("data-canonical-src")
		} else if (!/^[a-z]+\:\/\//i.test(element.src)) {
			element.src = new URL(element.src, document.baseURI).href;
		}
	});
}

// Wrap tables in an overflow-x: auto; div
function wrapTables() {
	var tables = document.querySelectorAll("div.articleBody table");

	for (table of tables) {
		var wrapper = document.createElement("div");
		wrapper.className = "nnw-overflow";
		table.parentNode.insertBefore(wrapper, table);
		wrapper.appendChild(table);

		// A negative side margin — usually from the site's own page layout —
		// would put part of the table where the wrapper can't scroll to it.
		if (parseFloat(getComputedStyle(table).marginLeft) < 0) {
			table.style.marginLeft = "0";
		}
		if (parseFloat(getComputedStyle(table).marginRight) < 0) {
			table.style.marginRight = "0";
		}
	}
}

// Add the playsinline attribute to any HTML5 videos that don"t have it.
// Without this attribute videos may autoplay and take over the whole screen
// on an iphone when viewing an article.
function inlineVideos() {
	document.querySelectorAll("video").forEach(element => {
		element.setAttribute("playsinline", true);
		if (!element.classList.contains("nnwAnimatedGIF")) {
			element.setAttribute("controls", true);
			element.removeAttribute("autoplay");
		}
	});
}

// Remove some children (currently just spans) from pre elements to work around a strange clipping issue
var ElementUnwrapper = {
	unwrapSelector: "span",
	unwrapElement: function (element) {
		var parent = element.parentNode;
		var children = Array.from(element.childNodes);

		for (child of children) {
			parent.insertBefore(child, element);
		}

		parent.removeChild(element);
	},
	// `elements` can be a selector string, an element, or a list of elements
	unwrapAppropriateChildren: function (elements) {
		if (typeof elements[Symbol.iterator] !== 'function')
			elements = [elements];
		else if (typeof elements === "string")
			elements = document.querySelectorAll(elements);

		for (element of elements) {
			for (unwrap of element.querySelectorAll(this.unwrapSelector)) {
				this.unwrapElement(unwrap);
			}

			element.normalize()
		}
	}
};

function flattenPreElements() {
	ElementUnwrapper.unwrapAppropriateChildren("div.articleBody td > pre");
}

function reloadArticleImage(imageSrc) {
	var image = document.getElementById("nnwImageIcon");
	image.src = imageSrc + "?" + new Date().getTime();
}

function stopMediaPlayback() {
	document.querySelectorAll("iframe").forEach(element => {
		var iframeSrc = element.src;
		element.src = iframeSrc;
	});

	// We pause all videos that have controls.  Video without controls shouldn't
	// have sound and are actually converted gifs.  Basically if the user can't
	// start the video again, don't stop it.
	document.querySelectorAll("video, audio").forEach(element => {
		if (element.hasAttribute("controls")) {
			element.pause();
		}
	});
}

function error() {
	document.body.innerHTML = "error";
}

// Takes into account absoluting of URLs.
function isLocalFootnote(target) {
	return (target.hash.startsWith("#fn") || target.hash.startsWith("#footnote")) && target.href.indexOf(document.baseURI) === 0;
}

function styleLocalFootnotes() {
	// Multimarkdown-style: <sup><a href="#fn…">. Substack-style: a bare
	// <a id="footnote-anchor-N" href="#footnote-N"> with no <sup> wrapper.
	for (elem of document.querySelectorAll("sup > a[href*='#fn'], sup > div > a[href*='#fn'], a[id^='footnote-anchor-']")) {
		if (isLocalFootnote(elem)) {
			elem.classList.add("footnote");
		}
	}
}

// convert <img alt="📰" src="[...]" class="wp-smiley"> to a text node containing 📰
// Tailwind size classes like w-[22px] and h-[22px] encode an SVG icon's intended size.
// The site stylesheet that implements them is stripped, so apply the sizes directly —
// otherwise an SVG with no width and height renders at full column width.
function sizeTailwindSVGs() {
	document.querySelectorAll("div.articleBody svg").forEach(svg => {
		const classAttribute = svg.getAttribute("class") || "";
		const width = classAttribute.match(/(?:^|\s)w-\[([\d.]+(?:px|em|rem))\]/);
		if (width) {
			svg.style.width = width[1];
		}
		const height = classAttribute.match(/(?:^|\s)h-\[([\d.]+(?:px|em|rem))\]/);
		if (height) {
			svg.style.height = height[1];
		}
	});
}

// A chart drawn in SVG but coloured by the site's stylesheet, which isn't kept, has nothing
// left to paint it but the default black, so its shapes become solid blocks. Hide it; the
// text around it usually says what it showed.
function hideUnpaintedSVGs() {
	document.querySelectorAll("div.articleBody svg").forEach(svg => {
		const shapes = svg.querySelectorAll("rect, circle, ellipse, path, polygon, polyline, line");
		if (shapes.length >= 10 && !svg.matches("[fill], [stroke], [style]") && !svg.querySelector("[fill], [stroke], [style]")) {
			svg.style.display = "none";
		}
	});
}

// Headings often link to themselves so a reader can copy a link to the section: the whole
// heading (<h2 id="yes"><a href="…#yes">Yes</a></h2>) or a mark beside it (#, ¶, §, or an
// icon with words for screen readers, like "Copy link to heading"). In a saved page these
// only look like links, so keep the heading's words and drop the marks.
function unlinkHeadingAnchors() {
	const page = new URL(document.baseURI);
	const path = url => url.origin + url.pathname.replace(/\/$/, "");
	document.querySelectorAll("div.articleBody :is(h1, h2, h3, h4, h5, h6) a[href*='#']").forEach(link => {
		let target;
		try {
			target = new URL(link.href);
		} catch (e) {
			return;
		}
		const heading = link.closest("h1, h2, h3, h4, h5, h6");
		if (path(target) !== path(page) && target.hash !== "#" + heading.id) {
			return;
		}
		const isMark = text => /^[\s\u200B#¶§🔗]*$/u.test(text);
		if (isMark(link.textContent) || !isMark(heading.textContent.replace(link.textContent, ""))) {
			link.remove();
		} else {
			link.replaceWith(...link.childNodes);
		}
	});
}

// Highlighters that put each line of code in a <div> came out of Readability with each line
// in a paragraph too, so code was double-spaced. Make them plain lines again. Pages saved
// since extraction learned this (prepare.js) arrive joined, with their blank lines.
function joinCodeLines() {
	document.querySelectorAll("div.articleBody pre").forEach(pre => {
		const container = pre.querySelector(":scope > code") || pre;
		const lines = [...container.children].filter(child => child.matches("div, p"));
		if (lines.length === 0) {
			return;
		}
		[...container.childNodes].forEach(node => {
			if (node.nodeType === Node.TEXT_NODE && !node.textContent.trim()) {
				node.remove();
			}
		});
		lines.forEach((line, index) => {
			line.querySelectorAll("div, p").forEach(block => block.replaceWith(...block.childNodes));
			// Some highlighters put a line break in empty lines already.
			line.replaceWith(...line.childNodes, index < lines.length - 1 && !line.textContent.endsWith("\n") ? "\n" : "");
		});
	});
}

// A link left with nothing in it (its icon was a site style) shows only as a stray underline.
function removeEmptyLinks() {
	document.querySelectorAll("div.articleBody a[href]").forEach(link => {
		if (!link.textContent.replace(/[\s\u200B]/g, "") && !link.querySelector("img, svg, picture, video, iframe")) {
			link.remove();
		}
	});
}

// A heading the site typed in capitals (and set small with its own styles) shouts at
// heading size; stylesheet.css sets these in small capitals instead.
function markCapitalHeadings() {
	document.querySelectorAll("div.articleBody :is(h1, h2, h3, h4, h5, h6)").forEach(heading => {
		const text = heading.textContent;
		if (/\p{Lu}.*\p{Lu}/su.test(text) && text === text.toUpperCase()) {
			heading.classList.add("nnw-capitals");
		}
	});
}

// Puts a space between two pieces of text that a site's stylesheet set apart, where the
// first ends and the second starts with a letter or digit.
function spaceApart(first, second) {
	if (/[\p{L}\p{N}]$/u.test(first.textContent) && /^[\p{L}\p{N}]/u.test(second.textContent)) {
		first.after(document.createTextNode(" "));
	}
}

// A caption's leading label ("<b>FIG A</b><span>Terminal-Bench…") and a code block's title
// bar ("<p>CODE<span>Shell</span></p>" or a file name, alone with its <pre> in a <div>) run
// their words together without the site's styles. The title bar would also read as a line of
// body text, so it's marked for stylesheet.css to set as a small label.
function separateLabels() {
	document.querySelectorAll("div.articleBody figcaption > :is(b, strong):first-child").forEach(label => {
		if (label.nextSibling) {
			spaceApart(label, label.nextSibling);
		}
	});
	document.querySelectorAll("div.articleBody pre").forEach(pre => {
		// The block holding the <pre>, taking in any <div>s it fills alone, and the one
		// element before it in their shared <div>, down to the paragraph holding its words.
		let block = pre;
		while (block.parentElement.matches("div:not(.articleBody)") && block.parentElement.children.length === 1) {
			block = block.parentElement;
		}
		let label = block.previousElementSibling;
		if (!label || label.previousElementSibling || block.nextElementSibling || !block.parentElement.matches("div")) {
			return;
		}
		while (label.children.length === 1 && label.firstElementChild.matches("div, p") && label.textContent.trim() === label.firstElementChild.textContent.trim()) {
			label = label.firstElementChild;
		}
		const text = label.textContent.trim();
		if (!label.matches("div, p") || !text || text.length > 40 || /[.:!?]$/.test(text) || label.querySelector("a, img, pre")) {
			return;
		}
		label.classList.add("nnw-code-label");
		const walker = document.createTreeWalker(label, NodeFilter.SHOW_TEXT);
		const pieces = [];
		while (walker.nextNode()) {
			pieces.push(walker.currentNode);
		}
		for (let i = 1; i < pieces.length; i++) {
			spaceApart(pieces[i - 1], pieces[i]);
		}
	});
}

function removeWpSmiley() {
	for (const img of document.querySelectorAll("img.wp-smiley[alt]")) {
		 img.parentNode.replaceChild(document.createTextNode(img.alt), img);
	}
}

// <https://github.com/Ranchero-Software/NetNewsWire/issues/3501>
function removeInstapaperIgnoreElements() {
	document.querySelectorAll(".instapaper_ignore").forEach(element => element.remove());
}

function processPage() {
	// stripStyles must run first — wrapFrames sets aspect-ratio on fixed-size iframes, which stripStyles would remove.
	stripStyles();
	wrapFrames();
	wrapTables();
	inlineVideos();
	sizeTailwindSVGs();
	hideUnpaintedSVGs();
	unlinkHeadingAnchors();
	removeEmptyLinks();
	joinCodeLines();
	markCapitalHeadings();
	separateLabels();
	constrainBodyRelativeIframes();
	convertImgSrc();
	flattenPreElements();
	styleLocalFootnotes();
	removeWpSmiley()
	removeInstapaperIgnoreElements();
	postRenderProcessing();
}

document.addEventListener("DOMContentLoaded", function(event) {
	processPage();
})
