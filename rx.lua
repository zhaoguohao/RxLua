local rx

local function noop() end
local function identity(x) return x end

--- @class Observer
-- @description Observers are simple objects that receive values from Observables.
local Observer = {}
Observer.__index = Observer

--- Creates a new Observer.
-- @arg {function=} onNext - Called when the Observable produces a value.
-- @arg {function=} onError - Called when the Observable terminates due to an error.
-- @arg {function=} onComplete - Called when the Observable completes normally.
-- @returns {Observer}
function Observer.create(onNext, onError, onComplete)
  local self = {
    _onNext = onNext or noop,
    _onError = onError or error,
    _onComplete = onComplete or noop,
    stopped = false
  }

  return setmetatable(self, Observer)
end

--- Pushes a new value to the Observer.
-- @arg {*} value
function Observer:onNext(value)
  if not self.stopped then
    self._onNext(value)
  end
end

--- Notify the Observer that an error has occurred.
-- @arg {string=} message - A string describing what went wrong.
function Observer:onError(message)
  if not self.stopped then
    self.stopped = true
    self._onError(message)
  end
end

--- Notify the Observer that the sequence has completed and will produce no more values.
function Observer:onComplete()
  if not self.stopped then
    self.stopped = true
    self._onComplete()
  end
end

--- @class Observable
-- @description Observables push values to Observers.
local Observable = {}
Observable.__index = Observable

--- Creates a new Observable.
-- @arg {function} subscribe - The subscription function that produces values.
-- @returns {Observable}
function Observable.create(subscribe)
  local self = {
    _subscribe = subscribe
  }

  return setmetatable(self, Observable)
end

--- Creates an Observable that produces a single value.
-- @arg {*} value
-- @returns {Observable}
function Observable.fromValue(value)
  return Observable.create(function(observer)
    observer:onNext(value)
    observer:onComplete()
  end)
end

--- Creates an Observable that produces values when the specified coroutine yields.
-- @arg {thread} coroutine
-- @returns {Observable}
function Observable.fromCoroutine(thread)
  thread = type(thread) == 'function' and coroutine.create(thread) or thread
  return Observable.create(function(observer)
    return rx.scheduler:schedule(function()
      while not observer.stopped do
        local success, value = coroutine.resume(thread)

        if success then
          observer:onNext(value)
        else
          return observer:onError(value)
        end

        if coroutine.status(thread) == 'dead' then
          return observer:onComplete()
        end

        coroutine.yield()
      end
    end)
  end)
end

--- Shorthand for creating an Observer and passing it to this Observable's subscription function.
-- @arg {function} onNext - Called when the Observable produces a value.
-- @arg {function} onError - Called when the Observable terminates due to an error.
-- @arg {function} onComplete - Called when the Observable completes normally.
function Observable:subscribe(onNext, onError, onComplete)
  return self._subscribe(Observer.create(onNext, onError, onComplete))
end

--- Subscribes to this Observable and prints values it produces.
-- @arg {string=} name - Prefixes the printed messages with a name.
function Observable:dump(name)
  name = name and (name .. ' ') or ''

  local onNext = function(x) print(name .. 'onNext: ' .. (x or '')) end
  local onError = function(e) print(name .. 'onError: ' .. e) end
  local onComplete = function() print(name .. 'onComplete') end

  return self:subscribe(onNext, onError, onComplete)
end

-- The functions below transform the values produced by an Observable and return a new Observable
-- that produces these values.

--- Returns a new Observable that only produces the first result of the original.
-- @returns {Observable}
function Observable:first()
  return Observable.create(function(observer)
    local function onNext(x)
      observer:onNext(x)
      observer:onComplete()
    end

    local function onError(e)
      observer:onError(e)
    end

    local function onComplete()
      observer:onComplete()
    end

    return self:subscribe(onNext, onError, onComplete)
  end)
end

--- Returns a new Observable that only produces the last result of the original.
-- @returns {Observable}
function Observable:last()
  return Observable.create(function(observer)
    local value

    local function onNext(x)
      value = x
    end

    local function onError(e)
      observer:onError(e)
    end

    local function onComplete()
      observer:onNext(value)
      observer:onComplete()
    end

    return self:subscribe(onNext, onError, onComplete)
  end)
end

--- Returns a new Observable that produces the values of the original transformed by a function.
-- @arg {function} callback - The function to transform values from the original Observable.
-- @returns {Observable}
function Observable:map(callback)
  return Observable.create(function(observer)
    callback = callback or identity

    local function onNext(x)
      return observer:onNext(callback(x))
    end

    local function onError(e)
      observer:onError(e)
    end

    local function onComplete()
      observer:onComplete()
    end

    return self:subscribe(onNext, onError, onComplete)
  end)
end

--- Returns a new Observable that produces a single value computed by accumulating the results of
-- running a function on each value produced by the original Observable.
-- @arg {function} accumulator - Accumulates the values of the original Observable. Will be passed
--                               the return value of the last call as the first argument and the
--                               current value as the second.
-- @arg {*} seed - A value to pass to the accumulator the first time it is run.
-- @returns {Observable}
function Observable:reduce(accumulator, seed)
  return Observable.create(function(observer)
    local result

    local function onNext(x)
      result = result or seed or x
      result = accumulator(result, x)
    end

    local function onError(e)
      observer:onError(e)
    end

    local function onComplete()
      observer:onNext(result)
      observer:onComplete()
    end

    return self:subscribe(onNext, onError, onComplete)
  end)
end

--- Returns a new Observable that produces the sum of the values of the original Observable as a
-- single result.
-- @returns {Observable}
function Observable:sum()
  return self:reduce(function(x, y) return x + y end, 0)
end

--- Returns a new Observable that runs a combinator function on the most recent values from a set
-- of Observables whenever any of them produce a new value. The results of the combinator function
-- are produced by the new Observable.
-- @arg {Observable...} observables - One or more Observables to combine.
-- @arg {function} combinator - A function that combines the latest result from each Observable and
--                              returns a single value.
-- @returns {Observable}
function Observable:combineLatest(...)
  local sources = {...}
  local combinator = table.remove(sources)
  table.insert(sources, 1, self)

  return Observable.create(function(observer)
    local latest = {}
    local pending = {unpack(sources)}
    local completed = {}

    local function onNext(i)
      return function(value)
        latest[i] = value
        pending[i] = nil

        if not next(pending) then
          observer:onNext(combinator(unpack(latest)))
        end
      end
    end

    local function onError(e)
      observer:onError(e)
    end

    local function onComplete(i)
      return function()
        table.insert(completed, i)

        if #completed == #sources then
          observer:onComplete()
        end
      end
    end

    for i = 1, #sources do
      sources[i]:subscribe(onNext(i), onError, onComplete(i))
    end
  end)
end

--- Returns a new Observable that produces the values from the original with duplicates removed.
-- @returns {Observable}
function Observable:distinct()
  return Observable.create(function(observer)
    local values = {}

    local function onNext(x)
      if not values[x] then
        observer:onNext(x)
      end

      values[x] = true
    end

    local function onError(e)
      observer:onError(e)
    end

    local function onComplete()
      observer:onComplete()
    end

    return self:subscribe(onNext, onError, onComplete)
  end)
end

--- @class Scheduler
-- @description Schedulers manage groups of Observables.
local Scheduler = {}

--- @class CooperativeScheduler
-- @description Manages Observables using coroutines and a virtual clock that must be updated
-- manually.
local Cooperative = {}
Cooperative.__index = Cooperative

--- Creates a new Cooperative Scheduler.
-- @arg {number=0} currentTime - A time to start the scheduler at.
-- @returns {Scheduler.Cooperative}
function Cooperative.create(currentTime)
  local self = {
    tasks = {},
    currentTime = currentTime or 0
  }

  return setmetatable(self, Cooperative)
end

--- Schedules a function to be run after an optional delay.
-- @arg {function} action - The function to execute. Will be converted into a coroutine. The
--                          coroutine may yield execution back to the scheduler with an optional
--                          number, which will put it to sleep for a time period.
-- @arg {number=0} delay - Delay execution of the action by a time period.
function Cooperative:schedule(action, delay)
  table.insert(self.tasks, {
    thread = coroutine.create(action),
    due = self.currentTime + (delay or 0)
  })
end

--- Triggers an update of the Cooperative Scheduler. The clock will be advanced and the scheduler
-- will run any coroutines that are due to be run.
-- @arg {number=0} delta - An amount of time to advance the clock by. It is common to pass in the
--                         time in seconds or milliseconds elapsed since this function was last
--                         called.
function Cooperative:update(delta)
  self.currentTime = self.currentTime + (delta or 0)

  for i = #self.tasks, 1, -1 do
    local task = self.tasks[i]

    if self.currentTime >= task.due then
      local success, delay = coroutine.resume(task.thread)

      if success then
        task.due = math.max(task.due + (delay or 0), self.currentTime)
      else
        error(delay)
      end

      if coroutine.status(task.thread) == 'dead' then
        table.remove(self.tasks, i)
      end
    end
  end
end

--- Returns whether or not the Cooperative Scheduler's queue is empty.
function Cooperative:isEmpty()
  return not next(self.tasks)
end

Scheduler.Cooperative = Cooperative

local Subject = setmetatable({}, Observable)
Subject.__index = Subject

function Subject.create(initialValue)
  local self = {
    observers = {}
  }

  return setmetatable(self, Subject)
end

function Subject:subscribe(onNext, onError, onComplete)
  table.insert(self.observers, Observer.create(onNext, onError, onComplete))
end

function Subject:onNext(value)
  for i = 1, #self.observers do
    self.observers[i]:onNext(value)
  end
end

rx = {
  Observer = Observer,
  Observable = Observable,
  Scheduler = Scheduler,
  scheduler = Scheduler.Cooperative.create(),
  Subject = Subject
}

return rx