--!strict

-- Code based on https://github.com/luau-lang/luau/blob/6169fa15d85c766c108c90eb68289021b5eee705/tools/perfgraph.py
-- Code based on https://github.com/luau-lang/luau/blob/6169fa15d85c766c108c90eb68289021b5eee705/tools/perfstat.py

local io = zune.io
local fs = zune.fs

local args = zune.process.args

local svg = require("./svg")

local function nodeFromCallstackListFile(input: string): svg.Node
	local dump = input:split("\n")
	local root = svg.Node.new()

	for _, l in dump do
		if l ~= "" then
			local ticks, stack = l:match("^(%d+)%s+(.*)$")
			assert(ticks and stack, `Malformed line in callstack list file: {l}`)
			local node = root

			for _, f in svg.reversed(stack:split(";")) do
				local source, function_name, line = f:match("^(.-),(.-),(.-)$")
				assert(source and function_name and line, `Malformed frame in callstack: {f}`)

				local child = node:child(f)
				child.function_name = function_name
				child.source = source
				child.line = tonumber(line) or 0

				node = child
			end

			node.ticks += tonumber(ticks) or error("Malformed ticks count")
		end
	end

	return root
end

if args[2] == "stats" then
	assert(args[3], "Usage: perfgraph stats <input_file>")

	local stats = {}
	local total = 0
	local total_gc = 0

	local dump = fs.readFile(args[3] :: string) :: string

	for _, l in dump:split("\n") do
		if l ~= "" then
			local ticks, stack = l:match("^(%d+)%s+(.*)$")
			assert(ticks and stack, `Malformed line in callstack list file: {l}`)
			local hier = {}

			for _, f in svg.reversed(stack:split(";")) do
				local source, function_name, line = f:match("^(.-),(.-),(.-)$")
				assert(source and function_name and line, `Malformed frame in callstack: {f}`)

				if not stats[f] then
					stats[f] = {
						function_name = function_name,
						source = source,
						line = tonumber(line) or 0,
						self_ticks = 0,
						hier_ticks = 0,
					}
				end

				local node = stats[f]

				if not hier[node] then
					node.hier_ticks += tonumber(ticks) or 0
					hier[node] = true
				end
			end

			total += tonumber(ticks) or 0
			local last_f = stack:match("([^;]+)$")
			assert(last_f, "Malformed stack trace")
			local node = stats[last_f]
			node.self_ticks += tonumber(ticks) or 0

			if node.source == "GC" then
				total_gc += tonumber(ticks) or 0
			end
		end
	end

	if total > 0 then
		print(`Runtime: {string.format("%d", total)} usec ({string.format("%.2f", 100.0 * total_gc / total)}% GC)`)
		print()
		print("Top functions (self time):")
		local sorted_self = {}
		for _, n in stats do
			table.insert(sorted_self, n)
		end
		table.sort(sorted_self, function(a, b)
			return a.self_ticks > b.self_ticks
		end)
		for i = 1, math.min(10, #sorted_self) do
			local n = sorted_self[i]
			print(
				string.format(
					"%12s usec (%.2f%%): %s",
					string.format("%d", n.self_ticks),
					100.0 * n.self_ticks / total,
					n.function_name
				)
			)
		end
		print()
		print("Top functions (total time):")
		local sorted_hier = {}
		for _, n in stats do
			table.insert(sorted_hier, n)
		end
		table.sort(sorted_hier, function(a, b)
			return a.hier_ticks > b.hier_ticks
		end)
		for i = 1, math.min(10, #sorted_hier) do
			local n = sorted_hier[i]
			print(
				string.format(
					"%12s usec (%.2f%%): %s",
					string.format("%d", n.hier_ticks),
					100.0 * n.hier_ticks / total,
					n.function_name
				)
			)
		end
	end
elseif args[2] == "graph" then
	assert(args[3], "Usage: perfgraph <input_file>")

	local root = nodeFromCallstackListFile(fs.readFile(args[3]) :: string)

	svg.layout(root, function(n: svg.Node): number
		return n.ticks
	end)
	local handle = io.stdout
	local out = args[4]
	if out then
		handle = fs.createFile(out, {
			truncate = true,
			exclusive = false,
		})
		handle:seekTo(0)
	end
	svg.display(handle, root, "Flame Graph", "hot", true)
else
	print("Usage: perfgraph <stats|graph> [options]")
	zune.process.exit(1)
end
