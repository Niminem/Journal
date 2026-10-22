## lan.nim - reach the journal from another machine on the network.
##
## Neel in serve mode listens on 127.0.0.1 only. This module listens on
## this computer's own network address, on the same port, and copies each
## connection to that loopback listener. Neel is told the network address
## as an allowed origin, so the browser's Host and Origin headers pass.
##
## `--lan` uses port 8770. `--lan:9000` picks another port.

import std/[locks, nativesockets, net, os, selectors, strutils]
when not defined(windows):
  import std/posix

type
  LanError* = object of CatchableError
    ## The network address could not be found, or the proxy could not listen.

  Launch* = object
    lan*: bool
    port*: int
    help*: bool

  Proxy* = ref object
    listener: Socket
    targetHost: string
    targetPort: int
    started: bool
    acceptThread: Thread[Proxy]

  Side = object
    src: Socket
    dst: Socket
    pending: seq[byte]
    reading: bool

const
  DefaultLanPort* = 8770

var activeProxy: Proxy
  ## The proxy the accept thread is serving. Set once, before that thread
  ## starts, and not changed while it runs.

# --- command line ---------------------------------------------------------------

proc parsePort(text: string): int =
  if text.len == 0:
    raise newException(ValueError, "A port has to follow --lan:")
  try:
    result = parseInt(text)
  except ValueError:
    raise newException(ValueError, "The port must be a number, not '" & text & "'")
  if result notin 1 .. 65535:
    raise newException(ValueError, "The port must be from 1 to 65535.")

proc parseLaunch*(args: openArray[string]): Launch =
  ## `--lan` serves on `DefaultLanPort`. `--lan:<port>` picks the port.
  result.port = DefaultLanPort
  for arg in args:
    if arg == "--":
      discard
    elif arg == "--lan":
      result.lan = true
    elif arg.startsWith("--lan:"):
      result.lan = true
      result.port = parsePort(arg["--lan:".len .. ^1])
    elif arg == "--help" or arg == "-h":
      result.help = true
    else:
      raise newException(ValueError, "Unknown argument '" & arg & "'. Try --help.")

proc usageText*(): string =
  """Journal

  nim r src/journal.nim
      Open a window on this computer.

  nim r src/journal.nim -- --lan
      Serve on this computer's network address, port 8770.

  nim r src/journal.nim -- --lan:9000
      The same, on another port.
"""

proc lanOrigin*(ip: string; port: int): string =
  ## The origin a browser sends when it opens `ip` on `port`.
  let host = if ':' in ip: "[" & ip & "]" else: ip
  "http://" & host & ":" & $port

proc thisLanAddress*(): string =
  ## The address this computer uses to reach the internet. No traffic is sent.
  try:
    result = $getPrimaryIPAddr()
  except OSError, IOError, ValueError:
    let e = getCurrentException()
    raise newException(LanError, "Could not find this computer's network address. " & e.msg)

# --- the copy -------------------------------------------------------------------

proc wouldBlock(err: OSErrorCode): bool =
  when defined(windows):
    int32(err) == 10035 # WSAEWOULDBLOCK
  else:
    int32(err) == EAGAIN or int32(err) == EWOULDBLOCK

proc rawSocket(): Socket =
  newSocket(AF_INET, SOCK_STREAM, IPPROTO_TCP, buffered = false)

proc takeIn(side: var Side) =
  ## Read whatever is waiting on `src` into `pending`. A closed source
  ## stops this direction.
  if not side.reading or side.pending.len > 0:
    return
  var buf: array[32768, byte]
  let n = side.src.recv(addr buf[0], buf.len)
  if n > 0:
    side.pending = @buf[0 ..< n]
  elif n == 0:
    side.reading = false
  elif not wouldBlock(osLastError()):
    side.reading = false

proc pushOut(side: var Side): bool =
  ## Write `pending` to `dst`. False when the destination is gone.
  result = true
  while side.pending.len > 0:
    let n = side.dst.send(addr side.pending[0], side.pending.len)
    if n > 0:
      side.pending = side.pending[n .. ^1]
    elif n == 0 or not wouldBlock(osLastError()):
      side.pending.setLen(0)
      side.reading = false
      return false
    else:
      break

proc bridge*(client: Socket; targetHost: string; targetPort: int) =
  ## Copy `client` to `targetHost:targetPort` until either side closes.
  let upstream = rawSocket()
  try:
    client.setSockOpt(OptNoDelay, true)
    upstream.setSockOpt(OptNoDelay, true)
    upstream.connect(targetHost, Port(targetPort))
  except OSError, IOError:
    try: client.close() except CatchableError: discard
    try: upstream.close() except CatchableError: discard
    return
  setBlocking(client.getFd, false)
  setBlocking(upstream.getFd, false)
  var
    toUp = Side(src: client, dst: upstream, reading: true)
    toClient = Side(src: upstream, dst: client, reading: true)
    sel = newSelector[bool]()
  sel.registerHandle(client.getFd, {Event.Read}, true)
  sel.registerHandle(upstream.getFd, {Event.Read}, false)
  try:
    while toUp.reading or toUp.pending.len > 0 or toClient.reading or
        toClient.pending.len > 0:
      let wantRead = {Event.Read}
      let wantWrite = {Event.Read, Event.Write}
      sel.updateHandle(client.getFd, if toClient.pending.len > 0: wantWrite else: wantRead)
      sel.updateHandle(upstream.getFd, if toUp.pending.len > 0: wantWrite else: wantRead)
      for key in sel.select(1000):
        if Event.Error in key.events:
          toUp.reading = false
          toClient.reading = false
          toUp.pending.setLen(0)
          toClient.pending.setLen(0)
          break
        if key.fd == int(client.getFd):
          if Event.Read in key.events: takeIn(toUp)
          if Event.Write in key.events and not pushOut(toClient):
            toUp.reading = false
        else:
          if Event.Read in key.events: takeIn(toClient)
          if Event.Write in key.events and not pushOut(toUp):
            toClient.reading = false
      if toUp.pending.len > 0: discard pushOut(toUp)
      if toClient.pending.len > 0: discard pushOut(toClient)
  except CatchableError:
    discard
  finally:
    sel.close()
    try: client.close() except CatchableError: discard
    try: upstream.close() except CatchableError: discard

var
  queueLock: Lock
  queueReady: Cond
  queue: seq[Socket]
  stopWorkers: bool
  workers: seq[Thread[void]]

initLock(queueLock)
initCond(queueReady)

proc runWorker() {.thread.} =
  while true:
    var client: Socket
    var done = false
    withLock queueLock:
      {.cast(gcsafe).}:
        while queue.len == 0 and not stopWorkers:
          wait(queueReady, queueLock)
        if queue.len == 0:
          done = true
        else:
          client = queue.pop()
    if done:
      break
    var host: string
    var port: int
    {.cast(gcsafe).}:
      host = activeProxy.targetHost
      port = activeProxy.targetPort
    bridge(client, host, port)

proc acceptLoop(proxy: Proxy) {.thread.} =
  while true:
    var client = rawSocket()
    try:
      proxy.listener.accept(client)
    except CatchableError:
      break
    withLock queueLock:
      {.cast(gcsafe).}:
        queue.add client
        signal(queueReady)

proc openProxy*(listenIp: string; listenPort: int; targetHost: string;
                targetPort: int): Proxy =
  ## Listen on `listenIp:listenPort` and copy connections to
  ## `targetHost:targetPort`. Raises `LanError` if the listen fails.
  result = Proxy(targetHost: targetHost, targetPort: targetPort)
  result.listener = rawSocket()
  result.listener.setSockOpt(OptReuseAddr, true)
  try:
    result.listener.bindAddr(Port(listenPort), listenIp)
    result.listener.listen()
  except OSError, IOError:
    let reason = getCurrentException().msg
    try:
      result.listener.close()
    except CatchableError:
      discard
    raise newException(LanError, "Could not listen on " & listenIp & ":" &
      $listenPort & ". " & reason)
  activeProxy = result
  if workers.len == 0:
    workers.setLen(4)
    for i in 0 ..< workers.len:
      createThread(workers[i], runWorker)
  createThread(result.acceptThread, acceptLoop, result)
  result.started = true

proc stop*(proxy: Proxy) =
  ## Close the listening socket and wait for the accept thread and the
  ## copy workers.
  if proxy.isNil or not proxy.started:
    return
  try:
    proxy.listener.close()
  except CatchableError:
    discard
  joinThread(proxy.acceptThread)
  withLock queueLock:
    {.cast(gcsafe).}:
      stopWorkers = true
      broadcast(queueReady)
  for worker in workers.mitems:
    joinThread(worker)
  proxy.started = false
