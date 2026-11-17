--!strict
-- Minimal signal for Tide.added / Tide.removed. Listeners run in their own
-- thread (task.spawn) so a yielding or erroring listener cannot break Tide.

export type Connection = { Connected: boolean, Disconnect: (self: Connection) -> () }
export type Signal = { fns: { (...any) -> () } }

local Signal = {}

function Signal.new(): Signal
	return { fns = {} }
end

function Signal.connect(signal: Signal, fn: (...any) -> ()): Connection
	assert(type(fn) == "function", "Tide: expected a function")
	table.insert(signal.fns, fn)
	local connection = { Connected = true } :: any
	function connection.Disconnect(self: any)
		if not self.Connected then
			return
		end
		self.Connected = false
		local index = table.find(signal.fns, fn)
		if index then
			table.remove(signal.fns, index)
		end
	end
	return connection
end

function Signal.fire(signal: Signal, ...: any)
	local fns = signal.fns
	if #fns == 0 then
		return
	end
	for _, fn in table.clone(fns) do
		task.spawn(fn, ...)
	end
end

return Signal
