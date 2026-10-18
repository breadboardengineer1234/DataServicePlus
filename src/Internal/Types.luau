local Signal = require(script.Parent.UsefulSignal)
local Config = require(script.Parent.Parent.Config)

export type Signal<T...> = Signal.Signal<T...>
export type Data = typeof(Config.template)
export type Connection<T...> = Signal.Connection<T...>
export type Path = any --({string} & {___hash: string}) | {___path: ({string} & {___hash: string})} | any

return nil
