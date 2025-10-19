--!strict

-- Code based on https://github.com/luau-lang/luau/blob/6169fa15d85c766c108c90eb68289021b5eee705/tools/svg.py

local Node = {}
Node.__index = Node

function Node.new()
	return setmetatable({
		name = "",
		children = {} :: { [string]: Node },
		function_name = "",
		source = "",
		line = 0,
		ticks = 0,
		depth = 0,
		width = 0,
		offset = 0,
	}, Node)
end

export type Node = typeof(Node.new())

function Node.child(self: Node, name: string): Node
	local node = self.children[name]
	if not node then
		node = Node.new()
		assert(node)
		node.name = name
		self.children[name] = node
	end
	return node
end

function Node.subtree(self: Node): { Node }
	local result: { Node } = { self }
	local offset = 1

	while offset <= #result do
		local p = result[offset]
		offset += 1
		for _, c in p.children do
			table.insert(result, c)
		end
	end

	return result
end

function Node.text(self: Node): string
	return self.function_name
end

function Node.title(self: Node): string
	return string.format("%s\n%s:%d", self.function_name, self.source, self.line)
end

function Node.details(self: Node, root: Node): string
	return string.format(
		"Function: %s [%s:%d] (%d usec, %.1f%%); self: %d usec",
		self.function_name,
		self.source,
		self.line,
		self.width,
		if root.width > 0 then (self.width / root.width * 100) else 0.0,
		self.ticks
	)
end

local function escape(s: string): string
	return s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
end

local function reversed<T>(t: { T }): { T }
	local result: { T } = {}
	for i = #t, 1, -1 do
		table.insert(result, t[i])
	end
	return result
end

local function sorted<T>(t: { [any]: T }, key: (T) -> any, reverse: boolean?): { T }
	local result: { T } = {}
	for _, v in t do
		table.insert(result, v)
	end
	table.sort(result, function(a: T, b: T): boolean
		if reverse then
			return key(a) > key(b)
		else
			return key(a) < key(b)
		end
	end)
	return result
end

local function layout(root: Node, widthcb: (Node) -> number)
	for _, n in reversed(root:subtree()) do
		-- propagate width to the parent
		n.width = widthcb(n)
		for _, c in n.children do
			n.width += c.width
		end
		-- compute offset from parent for every child in width order (layout order)
		local offset = 0
		for _, c in
			sorted(n.children, function(x: Node)
				return x.width
			end, true)
		do
			c.offset = offset
			offset += c.width
		end
	end

	for _, n in root:subtree() do
		for _, c in n.children do
			c.depth = n.depth + 1
			c.offset += n.offset
		end
	end
end

-- svg template (stolen from framegraph.pl)
local template = [===[<?xml version="1.0" standalone="no"?>
<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
<svg version="1.1" width="1200" height="$height" onload="init(evt)" viewBox="0 0 1200 $height" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">
<!-- Flame graph stack visualization. See https://github.com/brendangregg/FlameGraph for latest version, and http://www.brendangregg.com/flamegraphs.html for examples. -->
<defs>
    <linearGradient id="background" y1="0" y2="1" x1="0" x2="0" >
        <stop stop-color="$gradient-start" offset="5%" />
        <stop stop-color="$gradient-end" offset="95%" />
    </linearGradient>
</defs>
<style type="text/css">
    text { font-family:Verdana; font-size:12px; fill:rgb(0,0,0); }
    #search, #ignorecase { opacity:0.1; cursor:pointer; }
    #search:hover, #search.show, #ignorecase:hover, #ignorecase.show { opacity:1; }
    #subtitle { text-anchor:middle; font-color:rgb(160,160,160); }
    #title { text-anchor:middle; font-size:17px}
    #unzoom { cursor:pointer; }
    #frames > *:hover { stroke:black; stroke-width:0.5; cursor:pointer; }
    .hide { display:none; }
    .parent { opacity:0.5; }
</style>
<script type="text/ecmascript">
<![CDATA[
    "use strict";
    var details, searchbtn, unzoombtn, matchedtxt, svg, searching, currentSearchTerm, ignorecase, ignorecaseBtn;
    function init(evt) {
        details = document.getElementById("details").firstChild;
        searchbtn = document.getElementById("search");
        ignorecaseBtn = document.getElementById("ignorecase");
        unzoombtn = document.getElementById("unzoom");
        matchedtxt = document.getElementById("matched");
        svg = document.getElementsByTagName("svg")[0];
        searching = 0;
        currentSearchTerm = null;
    }

    window.addEventListener("click", function(e) {
        var target = find_group(e.target);
        if (target) {
            if (target.nodeName == "a") {
                if (e.ctrlKey === false) return;
                e.preventDefault();
            }
            if (target.classList.contains("parent")) unzoom();
            zoom(target);
        }
        else if (e.target.id == "unzoom") unzoom();
        else if (e.target.id == "search") search_prompt();
        else if (e.target.id == "ignorecase") toggle_ignorecase();
    }, false)

    // mouse-over for info
    // show
    window.addEventListener("mouseover", function(e) {
        var target = find_group(e.target);
        if (target) details.nodeValue = g_to_text(target);
    }, false)

    // clear
    window.addEventListener("mouseout", function(e) {
        var target = find_group(e.target);
        if (target) details.nodeValue = ' ';
    }, false)

    // ctrl-F for search
    window.addEventListener("keydown",function (e) {
        if (e.keyCode === 114 || (e.ctrlKey && e.keyCode === 70)) {
            e.preventDefault();
            search_prompt();
        }
    }, false)

    // ctrl-I to toggle case-sensitive search
    window.addEventListener("keydown",function (e) {
        if (e.ctrlKey && e.keyCode === 73) {
            e.preventDefault();
            toggle_ignorecase();
        }
    }, false)

    // functions
    function find_child(node, selector) {
        var children = node.querySelectorAll(selector);
        if (children.length) return children[0];
        return;
    }
    function find_group(node) {
        var parent = node.parentElement;
        if (!parent) return;
        if (parent.id == "frames") return node;
        return find_group(parent);
    }
    function orig_save(e, attr, val) {
        if (e.attributes["_orig_" + attr] != undefined) return;
        if (e.attributes[attr] == undefined) return;
        if (val == undefined) val = e.attributes[attr].value;
        e.setAttribute("_orig_" + attr, val);
    }
    function orig_load(e, attr) {
        if (e.attributes["_orig_"+attr] == undefined) return;
        e.attributes[attr].value = e.attributes["_orig_" + attr].value;
        e.removeAttribute("_orig_"+attr);
    }
    function g_to_text(e) {
        var text = find_child(e, "details").firstChild.nodeValue;
        return (text)
    }
    function g_to_func(e) {
        var child = find_child(e, "rawtext");
        return child ? child.textContent : null;
    }
    function update_text(e) {
        var r = find_child(e, "rect");
        var t = find_child(e, "text");
        var w = parseFloat(r.attributes.width.value) -3;
        var txt = find_child(e, "rawtext").textContent.replace(/\([^(]*\)$/,"");
        t.attributes.x.value = parseFloat(r.attributes.x.value) + 3;

        // Smaller than this size won't fit anything
        if (w < 2 * 12 * 0.59) {
            t.textContent = "";
            return;
        }

        t.textContent = txt;
        // Fit in full text width
        if (/^ *$/.test(txt) || t.getSubStringLength(0, txt.length) < w)
            return;

        for (var x = txt.length - 2; x > 0; x--) {
            if (t.getSubStringLength(0, x + 2) <= w) {
                t.textContent = txt.substring(0, x) + "..";
                return;
            }
        }
        t.textContent = "";
    }

    // zoom
    function zoom_reset(e) {
        if (e.attributes != undefined) {
            orig_load(e, "x");
            orig_load(e, "width");
        }
        if (e.childNodes == undefined) return;
        for (var i = 0, c = e.childNodes; i < c.length; i++) {
            zoom_reset(c[i]);
        }
    }
    function zoom_child(e, x, ratio) {
        if (e.attributes != undefined) {
            if (e.attributes.x != undefined) {
                orig_save(e, "x");
                e.attributes.x.value = (parseFloat(e.attributes.x.value) - x - 10) * ratio + 10;
                if (e.tagName == "text")
                    e.attributes.x.value = find_child(e.parentNode, "rect[x]").attributes.x.value + 3;
            }
            if (e.attributes.width != undefined) {
                orig_save(e, "width");
                e.attributes.width.value = parseFloat(e.attributes.width.value) * ratio;
            }
        }

        if (e.childNodes == undefined) return;
        for (var i = 0, c = e.childNodes; i < c.length; i++) {
            zoom_child(c[i], x - 10, ratio);
        }
    }
    function zoom_parent(e) {
        if (e.attributes) {
            if (e.attributes.x != undefined) {
                orig_save(e, "x");
                e.attributes.x.value = 10;
            }
            if (e.attributes.width != undefined) {
                orig_save(e, "width");
                e.attributes.width.value = parseInt(svg.width.baseVal.value) - (10 * 2);
            }
        }
        if (e.childNodes == undefined) return;
        for (var i = 0, c = e.childNodes; i < c.length; i++) {
            zoom_parent(c[i]);
        }
    }
    function zoom(node) {
        var attr = find_child(node, "rect").attributes;
        var width = parseFloat(attr.width.value);
        var xmin = parseFloat(attr.x.value);
        var xmax = parseFloat(xmin + width);
        var ymin = parseFloat(attr.y.value);
        var ratio = (svg.width.baseVal.value - 2 * 10) / width;

        // XXX: Workaround for JavaScript float issues (fix me)
        var fudge = 0.0001;

        unzoombtn.classList.remove("hide");

        var el = document.getElementById("frames").children;
        for (var i = 0; i < el.length; i++) {
            var e = el[i];
            var a = find_child(e, "rect").attributes;
            var ex = parseFloat(a.x.value);
            var ew = parseFloat(a.width.value);
            var upstack;
            // Is it an ancestor
            if ($flip == 1) {
                upstack = parseFloat(a.y.value) > ymin;
            } else {
                upstack = parseFloat(a.y.value) < ymin;
            }
            if (upstack) {
                // Direct ancestor
                if (ex <= xmin && (ex+ew+fudge) >= xmax) {
                    e.classList.add("parent");
                    zoom_parent(e);
                    update_text(e);
                }
                // not in current path
                else
                    e.classList.add("hide");
            }
            // Children maybe
            else {
                // no common path
                if (ex < xmin || ex + fudge >= xmax) {
                    e.classList.add("hide");
                }
                else {
                    zoom_child(e, xmin, ratio);
                    update_text(e);
                }
            }
        }
        search();
    }
    function unzoom() {
        unzoombtn.classList.add("hide");
        var el = document.getElementById("frames").children;
        for(var i = 0; i < el.length; i++) {
            el[i].classList.remove("parent");
            el[i].classList.remove("hide");
            zoom_reset(el[i]);
            update_text(el[i]);
        }
        search();
    }

    // search
    function toggle_ignorecase() {
        ignorecase = !ignorecase;
        if (ignorecase) {
            ignorecaseBtn.classList.add("show");
        } else {
            ignorecaseBtn.classList.remove("show");
        }
        reset_search();
        search();
    }
    function reset_search() {
        var el = document.querySelectorAll("#frames rect");
        for (var i = 0; i < el.length; i++) {
            orig_load(el[i], "fill")
        }
    }
    function search_prompt() {
        if (!searching) {
            var term = prompt("Enter a search term (regexp " +
                "allowed, eg: ^ext4_)"
                + (ignorecase ? ", ignoring case" : "")
                + "\nPress Ctrl-i to toggle case sensitivity", "");
            if (term != null) {
                currentSearchTerm = term;
                search();
            }
        } else {
            reset_search();
            searching = 0;
            currentSearchTerm = null;
            searchbtn.classList.remove("show");
            searchbtn.firstChild.nodeValue = "Search"
            matchedtxt.classList.add("hide");
            matchedtxt.firstChild.nodeValue = ""
        }
    }
    function search(term) {
        if (currentSearchTerm === null) return;
        var term = currentSearchTerm;

        var re = new RegExp(term, ignorecase ? 'i' : '');
        var el = document.getElementById("frames").children;
        var matches = new Object();
        var maxwidth = 0;
        for (var i = 0; i < el.length; i++) {
            var e = el[i];
            var func = g_to_func(e);
            var rect = find_child(e, "rect");
            if (func == null || rect == null)
                continue;

            // Save max width. Only works as we have a root frame
            var w = parseFloat(rect.attributes.width.value);
            if (w > maxwidth)
                maxwidth = w;

            if (func.match(re)) {
                // highlight
                var x = parseFloat(rect.attributes.x.value);
                orig_save(rect, "fill");
                rect.attributes.fill.value = "rgb(230,0,230)";

                // remember matches
                if (matches[x] == undefined) {
                    matches[x] = w;
                } else {
                    if (w > matches[x]) {
                        // overwrite with parent
                        matches[x] = w;
                    }
                }
                searching = 1;
            }
        }
        if (!searching)
            return;

        searchbtn.classList.add("show");
        searchbtn.firstChild.nodeValue = "Reset Search";

        // calculate percent matched, excluding vertical overlap
        var count = 0;
        var lastx = -1;
        var lastw = 0;
        var keys = Array();
        for (k in matches) {
            if (matches.hasOwnProperty(k))
                keys.push(k);
        }
        // sort the matched frames by their x location
        // ascending, then width descending
        keys.sort(function(a, b){
            return a - b;
        });
        // Step through frames saving only the biggest bottom-up frames
        // thanks to the sort order. This relies on the tree property
        // where children are always smaller than their parents.
        var fudge = 0.0001; // JavaScript floating point
        for (var k in keys) {
            var x = parseFloat(keys[k]);
            var w = matches[keys[k]];
            if (x >= lastx + lastw - fudge) {
                count += w;
                lastx = x;
                lastw = w;
            }
        }
        // display matched percent
        matchedtxt.classList.remove("hide");
        var pct = 100 * count / maxwidth;
        if (pct != 100) pct = pct.toFixed(1)
        matchedtxt.firstChild.nodeValue = "Matched: " + pct + "%";
    }
]]>
</script>
<rect x="0.0" y="0" width="1200.0" height="$height.0" fill="url(#background)"  />
<text id="title" x="600.00" y="24" >$title</text>
<text id="unzoom" x="10.00" y="24" class="hide">Reset Zoom</text>
<text id="search" x="1090.00" y="24" >Search</text>
<text id="ignorecase" x="1174.00" y="24" >ic</text>
<text id="matched" x="1090.00" y="$status" > </text>
<text id="details" x="10.00" y="$status" > </text>
<g id="frames">
]===]

local function namehash(s: string): number
	-- FNV-1a
	local hval = 0x811c9dc5
	for i = 1, #s do
		local ch = string.byte(s, i)
		hval = bit32.bxor(hval, ch)
		hval = (hval * 0x01000193) % (2 ^ 32)
	end
	return (hval % 31337) / 31337.0
end

local function display(handle: FileHandle, root: Node, title: string, colors: string, flip: boolean?)
	local gradient_start: string
	local gradient_end: string
	if colors == "cold" then
		gradient_start = "#eef2ee"
		gradient_end = "#e0ffe0"
	else
		gradient_start = "#eeeeee"
		gradient_end = "#eeeeb0"
	end

	local maxdepth = 0
	for _, n in root:subtree() do
		maxdepth = math.max(maxdepth, n.depth)
	end

	local svgheight = maxdepth * 16 + 3 * 16 + 2 * 16

	handle:append(
		(
			template
				:gsub("%$title", title)
				:gsub("%$gradient%-start", gradient_start)
				:gsub("%$gradient%-end", gradient_end)
				:gsub("%$height", tostring(svgheight))
				:gsub("%$status", tostring(if flip then (svgheight - 16 + 3) else (3 * 16 - 3)))
				:gsub("%$flip", tostring(if flip then 1 else 0))
		)
	)
	handle:append("\n")

	local framewidth = 1200 - 20

	local function pixels(x: number): number
		return if root.width > 0 then (x / root.width) * framewidth else 0
	end

	for _, n in root:subtree() do
		if pixels(n.width) < 0.1 then
			continue
		end

		local x = 10 + pixels(n.offset)
		local y = (if flip then (maxdepth - 1 - n.depth) else n.depth) * 16 + 3 * 16
		local width = pixels(n.width)
		local height = 15

		local fillr, fillg, fillb
		if colors == "cold" then
			fillr = 0
			fillg = math.floor(190 + 50 * namehash(n.name))
			fillb = math.floor(210 * namehash(string.reverse(n.name)))
		else
			fillr = math.floor(205 + 50 * namehash(n.name))
			fillg = math.floor(230 * namehash(string.reverse(n.name)))
			fillb = math.floor(55 * namehash(string.reverse(string.reverse(n.name))))
		end

		local fill = string.format("rgb(%d,%d,%d)", fillr, fillg, fillb)
		local chars = width / (12 * 0.59)
		local text = n:text()
		if chars >= 3 then
			if chars < #text then
				text = string.sub(text, 1, math.floor(chars - 2)) .. ".."
			end
		else
			text = ""
		end
		handle:append("<g>\n")
		handle:append("<title>" .. escape(n:title()) .. "</title>\n")
		handle:append("<details>" .. escape(n:details(root)) .. "</details>\n")
		handle:append(
			string.format(
				"<rect x='%.2f' y='%.2f' width='%.2f' height='%.2f' fill='%s' rx='2' ry='2' />\n",
				x,
				y,
				width,
				height,
				fill
			)
		)
		handle:append(string.format("<text x='%.2f' y='%.2f'>%s</text>\n", x + 3, y + 10.5, escape(text)))
		handle:append("<rawtext>" .. escape(n:text()) .. "</rawtext>\n")
		handle:append("</g>\n")
	end
	handle:append("</g>\n</svg>\n")
end

return {
	Node = Node,
	reversed = reversed,
	escape = escape,
	layout = layout,
	template = template,
	display = display,
}
