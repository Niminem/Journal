## lan.nim - reach the journal from another machine on the network.
##
## Neel in serve mode listens on 127.0.0.1 only. This module listens on
## this computer's own network address, on the same port, and copies each
## connection to that loopback listener. One thread copies all of them:
## the browser keeps the page's sockets open, and that must not leave the
## WebSocket waiting. Neel is told the network address as an allowed origin,
## so the browser's Host and Origin headers pass.
##
## `--lan` uses port 8770. `--lan:9000` picks another port.

import std/[atomics, nativesockets, net, os, selectors, strutils]
when defined(windows):
  import std/winlean
else:
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
    wake: SelectEvent
    targetHost: string
    targetPort: int
    started: bool
    stopRequested: Atomic[int]
    ioThread: Thread[Proxy]

  Side = object
    src: Socket
    dst: Socket
    pending: seq[byte]
    reading: bool

  Link = ref object
    ## One browser socket and the loopback socket it is copied to.
    toUp: Side
    toClient: Side
    dead: bool

const
  DefaultLanPort* = 8770

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

proc shutdownWrite(socket: Socket) =
  ## The peer stopped sending. The other end has to see that, or it waits
  ## forever for a byte that will not arrive. 1 is SD_SEND and SHUT_WR.
  when defined(windows):
    discard winlean.shutdown(socket.getFd, 1.cint)
  else:
    discard posix.shutdown(socket.getFd, posix.SHUT_WR)

proc takeIn(side: var Side) =
  ## Read whatever is waiting on `src` into `pending`. A closed source
  ## stops this direction and half-closes `dst`.
  if not side.reading or side.pending.len > 0:
    return
  var buf: array[32768, byte]
  let n = side.src.recv(addr buf[0], buf.len)
  if n > 0:
    side.pending = @buf[0 ..< n]
  elif n == 0:
    side.reading = false
    shutdownWrite(side.dst)
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

proc closeQuiet(socket: Socket) =
  if socket.isNil:
    return
  try:
    socket.close()
  except CatchableError:
    discard

proc bridge*(client: Socket; targetHost: string; targetPort: int) =
  ## Copy `client` to `targetHost:targetPort` until either side closes.
  let upstream = rawSocket()
  try:
    client.setSockOpt(OptNoDelay, true)
    upstream.setSockOpt(OptNoDelay, true)
    upstream.connect(targetHost, Port(targetPort))
  except OSError, IOError:
    closeQuiet(client)
    closeQuiet(upstream)
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
    closeQuiet(client)
    closeQuiet(upstream)

proc clientEvents(link: Link): set[Event] =
  if link.toUp.reading and link.toUp.pending.len == 0:
    result.incl Event.Read
  if link.toClient.pending.len > 0:
    result.incl Event.Write

proc upstreamEvents(link: Link): set[Event] =
  if link.toClient.reading and link.toClient.pending.len == 0:
    result.incl Event.Read
  if link.toUp.pending.len > 0:
    result.incl Event.Write

proc failLink(link: Link) =
  link.toUp.reading = false
  link.toClient.reading = false
  link.toUp.pending.setLen(0)
  link.toClient.pending.setLen(0)

proc retire(sel: Selector[int]; link: Link) =
  if link.dead:
    return
  link.dead = true
  try: sel.unregister(link.toUp.src.getFd) except CatchableError: discard
  try: sel.unregister(link.toClient.src.getFd) except CatchableError: discard
  closeQuiet(link.toUp.src)
  closeQuiet(link.toClient.src)

proc pump(link: Link) =
  if link.dead:
    return
  if link.toUp.pending.len > 0 and not pushOut(link.toUp):
    failLink(link)
  if link.toClient.pending.len > 0 and not pushOut(link.toClient):
    failLink(link)

proc finished(link: Link): bool =
  not link.toUp.reading and link.toUp.pending.len == 0 and
    not link.toClient.reading and link.toClient.pending.len == 0

proc settle(sel: Selector[int]; link: Link) =
  ## Write what was just read, then watch whichever direction still has work.
  if link.dead:
    return
  pump(link)
  if finished(link):
    retire(sel, link)
    return
  sel.updateHandle(link.toUp.src.getFd, clientEvents(link))
  sel.updateHandle(link.toClient.src.getFd, upstreamEvents(link))

proc stopping(proxy: Proxy): bool =
  load(proxy.stopRequested, moAcquire) != 0

proc admit(proxy: Proxy; sel: Selector[int]; links: var seq[Link]) =
  ## Accept every connection that is already waiting and connect each one
  ## to loopback. A full queue is drained before the copy loop waits again.
  while not stopping(proxy):
    var client: Socket
    try:
      proxy.listener.accept(client, flags = {})
    except OSError as err:
      if not wouldBlock(OSErrorCode(err.errorCode)):
        discard
      return
    let upstream = rawSocket()
    try:
      client.setSockOpt(OptNoDelay, true)
      upstream.setSockOpt(OptNoDelay, true)
      upstream.connect(proxy.targetHost, Port(proxy.targetPort))
      setBlocking(client.getFd, false)
      setBlocking(upstream.getFd, false)
    except OSError, IOError:
      closeQuiet(client)
      closeQuiet(upstream)
      continue
    let link = Link(
      toUp: Side(src: client, dst: upstream, reading: true),
      toClient: Side(src: upstream, dst: client, reading: true))
    let id = links.len
    links.add link
    sel.registerHandle(client.getFd, clientEvents(link), id)
    sel.registerHandle(upstream.getFd, upstreamEvents(link), id)

proc service(link: Link; fd: int; events: set[Event]) =
  if link.dead:
    return
  try:
    if Event.Error in events:
      failLink(link)
      return
    if fd == int(link.toUp.src.getFd):
      if Event.Read in events: takeIn(link.toUp)
      if Event.Write in events and not pushOut(link.toClient):
        failLink(link)
    else:
      if Event.Read in events: takeIn(link.toClient)
      if Event.Write in events and not pushOut(link.toUp):
        failLink(link)
  except CatchableError:
    failLink(link)

proc serveProxy(proxy: Proxy) {.thread.} =
  var
    sel = newSelector[int]()
    links: seq[Link]
  let listenerFd = int(proxy.listener.getFd)
  sel.registerHandle(proxy.listener.getFd, {Event.Read}, -1)
  sel.registerEvent(proxy.wake, -2)
  try:
    while not stopping(proxy):
      var keys: seq[ReadyKey]
      try:
        keys = sel.select(-1)
      except CatchableError:
        break
      for key in keys:
        if stopping(proxy) or Event.User in key.events:
          continue
        if key.fd == listenerFd:
          admit(proxy, sel, links)
          continue
        let id = sel.getData(key.fd)
        if id < 0 or id >= links.len:
          continue
        service(links[id], key.fd, key.events)
      for link in links:
        if not link.dead:
          settle(sel, link)
  finally:
    for link in links:
      if not link.isNil:
        retire(sel, link)
    try: sel.unregister(proxy.wake) except CatchableError: discard
    sel.close()
    try: proxy.wake.close() except CatchableError: discard
    closeQuiet(proxy.listener)

proc openProxy*(listenIp: string; listenPort: int; targetHost: string;
                targetPort: int): Proxy =
  ## Listen on `listenIp:listenPort` and copy connections to
  ## `targetHost:targetPort`. Raises `LanError` if the listen fails.
  ## `listenPort` of 0 lets the system choose; `listeningPort` reads it back.
  result = Proxy(targetHost: targetHost, targetPort: targetPort)
  result.listener = rawSocket()
  result.listener.setSockOpt(OptReuseAddr, true)
  try:
    result.listener.bindAddr(Port(listenPort), listenIp)
    result.listener.listen()
    setBlocking(result.listener.getFd, false)
  except OSError, IOError:
    let reason = getCurrentException().msg
    closeQuiet(result.listener)
    raise newException(LanError, "Could not listen on " & listenIp & ":" &
      $listenPort & ". " & reason)
  result.wake = newSelectEvent()
  createThread(result.ioThread, serveProxy, result)
  result.started = true

proc listeningPort*(proxy: Proxy): int =
  ## The port `openProxy` bound. Useful when it was asked for port 0.
  int(proxy.listener.getLocalAddr()[1])

proc stop*(proxy: Proxy) =
  ## Ask the copy thread to close every socket and wait for it.
  if proxy.isNil or not proxy.started:
    return
  store(proxy.stopRequested, 1, moRelease)
  try:
    proxy.wake.trigger()
  except CatchableError:
    discard
  joinThread(proxy.ioThread)
  proxy.started = false
