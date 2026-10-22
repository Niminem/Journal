## LAN address formatting, command line, and the byte copy in front of Neel.

import std/[net, unittest]
import journal/lan

proc listenOn(port: int): Socket =
  result = newSocket(AF_INET, SOCK_STREAM, IPPROTO_TCP, buffered = false)
  result.setSockOpt(OptReuseAddr, true)
  result.bindAddr(Port(port), "127.0.0.1")
  result.listen()

proc echoOnce(listener: Socket) {.thread.} =
  var client = newSocket()
  listener.accept(client)
  var buf: array[32, byte]
  let n = client.recv(addr buf[0], buf.len)
  var off = 0
  while off < n:
    let wrote = client.send(addr buf[off], n - off)
    if wrote <= 0:
      break
    off += wrote
  client.close()

proc echoHeld(listener: Socket) {.thread.} =
  ## Echo four bytes, then stay open until the caller closes. A proxy that
  ## can only copy a few connections at a time leaves the rest waiting here.
  var client = newSocket()
  try:
    listener.accept(client)
  except CatchableError:
    return
  var buf: array[4, byte]
  var got = 0
  while got < 4:
    let n = client.recv(addr buf[got], 4 - got)
    if n <= 0:
      client.close()
      return
    got += n
  var off = 0
  while off < 4:
    let n = client.send(addr buf[off], 4 - off)
    if n <= 0:
      break
    off += n
  var sink: array[8, byte]
  discard client.recv(addr sink[0], sink.len)
  client.close()

type Front = object
  listener: Socket
  port: int

proc acceptOne(front: Front) {.thread.} =
  var client = newSocket()
  front.listener.accept(client)
  bridge(client, "127.0.0.1", front.port)

suite "lan":
  test "the default is a local window":
    let launch = parseLaunch(newSeq[string]())
    check not launch.lan
    check launch.port == DefaultLanPort
    check not launch.help

  test "--lan serves on port 8770":
    let launch = parseLaunch(["--lan"])
    check launch.lan
    check launch.port == 8770
    let separated = parseLaunch(["--", "--lan"])
    check separated.lan
    check separated.port == 8770

  test "--lan:port overrides the port":
    let launch = parseLaunch(["--lan:9000"])
    check launch.lan
    check launch.port == 9000
    let again = parseLaunch(["--lan", "--lan:9100"])
    check again.port == 9100

  test "a bad port or unknown argument is rejected":
    expect ValueError:
      discard parseLaunch(["--lan:nope"])
    expect ValueError:
      discard parseLaunch(["--lan:0"])
    expect ValueError:
      discard parseLaunch(["--lan:"])
    expect ValueError:
      discard parseLaunch(["--serve"])

  test "help is recognized":
    check parseLaunch(["--help"]).help
    check parseLaunch(["-h"]).help

  test "an origin uses the address other machines will open":
    check lanOrigin("192.168.1.20", 8770) == "http://192.168.1.20:8770"
    check lanOrigin("fe80::1", 8770) == "http://[fe80::1]:8770"

  test "the proxy copies a short message to loopback and back":
    let backend = listenOn(0)
    let backendPort = int(backend.getLocalAddr()[1])
    var echo: Thread[Socket]
    createThread(echo, echoOnce, backend)

    let frontSocket = listenOn(0)
    let front = Front(listener: frontSocket, port: backendPort)
    var proxy: Thread[Front]
    createThread(proxy, acceptOne, front)

    var client = newSocket()
    client.connect("127.0.0.1", frontSocket.getLocalAddr()[1])
    client.send("ping")
    var reply = newString(4)
    let n = client.recv(reply, 4, timeout = 2000)
    check n == 4
    check reply == "ping"
    client.close()
    joinThread(echo)
    joinThread(proxy)
    backend.close()
    frontSocket.close()

  test "several open connections are copied together":
    const count = 6
    let backend = listenOn(0)
    let backendPort = int(backend.getLocalAddr()[1])
    var echoes: array[count, Thread[Socket]]
    for i in 0 ..< count:
      createThread(echoes[i], echoHeld, backend)
    var proxy: Proxy
    var clients: array[count, Socket]
    try:
      proxy = openProxy("127.0.0.1", 0, "127.0.0.1", backendPort)
      for i in 0 ..< count:
        clients[i] = newSocket()
        clients[i].connect("127.0.0.1", Port(proxy.listeningPort))
        clients[i].send("ping")
      for i in 0 ..< count:
        var reply = newString(4)
        let n = clients[i].recv(reply, 4, timeout = 1000)
        check n == 4
        check reply == "ping"
    finally:
      for client in clients:
        if not client.isNil:
          try: client.close() except CatchableError: discard
      if not proxy.isNil:
        proxy.stop()
      try: backend.close() except CatchableError: discard
      for echo in echoes.mitems:
        joinThread(echo)
