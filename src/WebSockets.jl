module WebSockets

using HttpCommon
using HttpServer
export WebSocket,
       WebSocketHandler,
       write,
       read,
       close,
       send_ping,
       send_pong

include("Base64.jl") #used for encoding handshake key

# A WebSocket is just a wrapper over a TcpSocket
# All it does is wrap outgoing data in the protocol
# and unwrapp incoming data.
type WebSocket
  id::Int
  socket::TcpSocket
  is_closed::Bool

  function WebSocket(id::Int,socket::TcpSocket)
    new(id,socket, !isopen(socket))
  end
end

#
# WebSocket Packets
#

#      0                   1                   2                   3
#      0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
#     +-+-+-+-+-------+-+-------------+-------------------------------+
#     |F|R|R|R| opcode|M| Payload len |    Extended payload length    |
#     |I|S|S|S|  (4)  |A|     (7)     |             (16/64)           |
#     |N|V|V|V|       |S|             |   (if payload len==126/127)   |
#     | |1|2|3|       |K|             |                               |
#     +-+-+-+-+-------+-+-------------+ - - - - - - - - - - - - - - - +
#     |     Extended payload length continued, if payload len == 127  |
#     + - - - - - - - - - - - - - - - +-------------------------------+
#     |                               |Masking-key, if MASK set to 1  |
#     +-------------------------------+-------------------------------+
#     | Masking-key (continued)       |          Payload Data         |
#     +-------------------------------- - - - - - - - - - - - - - - - +
#     :                     Payload Data continued ...                :
#     + - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - +
#     |                     Payload Data continued ...                |
#     +---------------------------------------------------------------+
#

# Opcode values
#  *  %x0 denotes a continuation frame
#  *  %x1 denotes a text frame
#  *  %x2 denotes a binary frame
#  *  %x3-7 are reserved for further non-control frames
#
#  *  %x8 denotes a connection close
#  *  %x9 denotes a ping
#  *  %xA denotes a pong
#  *  %xB-F are reserved for further control frames

# Internal function for wrapping one
# piece of data into a WS header
# sending it out over the TcpSocket.
function send_fragment(ws::WebSocket, islast::Bool, data::Array{Uint8}, opcode=0b0001)
  l = length(data)
  b1::Uint8 = (islast ? 0b1000_0000 : 0b0000_0000) | opcode
  if l <= 125
    write(ws.socket,b1)
    write(ws.socket,uint8(l))
    write(ws.socket,data)
  elseif l <= typemax(Uint16)
    write(ws.socket,b1)
    write(ws.socket,uint8(126))
    write(ws.socket,hton(uint16(l)))
    write(ws.socket,data)
  elseif l <= typemax(Uint64)
    write(ws.socket,b1)
    write(ws.socket,uint8(127))
    write(ws.socket,hton(uint64(l)))
    write(ws.socket,data)
  else
    error("Attempted to send too much data for one websocket fragment\n")
  end
end
send_fragment(ws::WebSocket, islast::Bool, data::ByteString, opcode=0b0001) =
  send_fragment(ws, islast, data.data, opcode)

# Exported function for sending data into a websocket
# data should allow length(data) and write(TcpSocket,data)
# all protocol details are taken care of.
import Base.write
function write(ws::WebSocket,data)
  if ws.is_closed
    @show ws
    error("attempt to write to closed WebSocket\n")
  end

  println("sending")
  #assume data fits in one fragment
  send_fragment(ws,true,data)
end

function send_ping(ws::WebSocket)
  send_fragment(ws, true, "", 0x9)
end

function send_pong(ws::WebSocket)
  send_fragment(ws, true, "", 0xA)
end

function close(ws::WebSocket)
  send_fragment(ws, true, "", 0x8)
  ws.is_closed = true
  # wait for their close frame, then close the Tcpsocket?
  close(ws.socket)
end


# represents one received message fragment
# (headers + data)
type WebSocketFragment
  is_last::Bool
  rsv1::Bool
  rsv2::Bool
  rsv3::Bool
  opcode::Uint8 #really, Uint4
  is_masked::Bool
  payload_len::Uint64
  maskkey::Vector{Uint8} #Union{Array{Uint8,4}, Nothing}
  data::Vector{Uint8} #ByteString
end

# constructor to do some conversions from bits to Bool.
function WebSocketFragment(
   fin::Uint8
  ,rsv1::Uint8
  ,rsv2::Uint8
  ,rsv3::Uint8
  ,opcode::Uint8
  ,masked::Uint8
  ,payload_len::Uint64
  ,maskkey::Vector{Uint8}
  ,data::Vector{Uint8})

  WebSocketFragment(
      bool(fin)
    , bool(rsv1)
    , bool(rsv2)
    , bool(rsv3)
    , opcode
    , bool(masked)
    , payload_len
    , maskkey
    , data)
end

# A message frame/fragment can be
# either a control frame or a data frame
# this function determines which it is
# according to the opcode.
function is_control_frame(msg::WebSocketFragment)
  return bool((msg.opcode & 0b0000_1000) >>> 3)
  # if that bit is set (1), then this is a control frame.
end

function handle_control_frame(ws::WebSocket,wsf::WebSocketFragment)

  println("handling control frame")
  @show wsf

  if wsf.opcode == 0x8 #  %x8 denotes a connection close
    println("closed!")
    #TODO: send close frame
    #TODO: close socket
  elseif wsf.opcode == 0x9 #  %x9 denotes a ping
    println("ping")
    #TODO: send pong
  elseif wsf.opcode == 0xA #  %xA denotes a pong
    println("pong")
    # nothing to do here...?
  else #  %xB-F are reserved for further control frames
    println("unknown opcode $(wsf.opcode)")
  end
end

function read_frame(ws::WebSocket)
  a = read(ws.socket,Uint8)
  fin    = a & 0b1000_0000 >>> 7 #if fin, then is final fragment
  rsv1   = a & 0b0100_0000 #if not 0, fail.
  rsv2   = a & 0b0010_0000 #if not 0, fail.
  rsv3   = a & 0b0001_0000 #if not 0, fail.
  opcode = a & 0b0000_1111 #if not known code, fail.
  #TODO: add validation somewhere to ensure rsv,opcode,mask,etc are valid.

  b = read(ws.socket,Uint8)
  mask = b & 0b1000_0000 >>> 7 #if not 1, fail.

  payload_len::Uint64 = b & 0b0111_1111
  if payload_len == 126
    payload_len = ntoh(read(ws.socket,Uint16)) #2 bytes
  elseif payload_len == 127
    payload_len = ntoh(read(ws.socket,Uint64)) #8 bytes
  end

  maskkey = Array(Uint8,4)
  for i in 1:4
   maskkey[i] = read(ws.socket,Uint8)
  end

  data = Array(Uint8, payload_len)
  for i in 1:payload_len
    d = read(ws.socket, Uint8)
    d = d $ maskkey[mod(i - 1, 4) + 1]
    print("$(convert(Char,d))")
    data[i] = d
  end
  println("")

  return WebSocketFragment(fin,rsv1,rsv2,rsv3,opcode,mask,payload_len,maskkey,data)
end

import Base.read
# Read data from a WebSocket.
# This will block until a full message has been received.
# The headers will be stripped and only the data will be returned.
function read(ws::WebSocket)
  if ws.is_closed
    error("Attempt to read from closed WebSocket")
  end

  frame = read_frame(ws)

  #handle control (non-data) messages
  if is_control_frame(frame)
    @show handle_control_frame(ws,frame)
    return read(ws)
  end

  #handle data that uses multiple fragments
  if !frame.is_last
    print("\n\thandling fragmented message\n")
    return concatenate(frame.data,read(ws))
  end

  return frame.data
end

#
# WebSocket Handshake
#

# get key out of request header
get_websocket_key(request::Request) = begin
  return request.headers["Sec-WebSocket-Key"]
end

# the protocol requires that a special key
# be processed and sent back with the handshake response
# to prove that received the HTTP request
# and that we *really* know what webSockets means.
generate_websocket_key(key) = begin
  magicstring = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  resp_key = readall(`echo -n $key$magicstring` |> `openssl dgst -sha1`)
  m = match(r"(?:\([^)]*\)=\s)?(.+)$", resp_key)
  bytes = hex2bytes(m.captures[1])
  return base64(bytes)
end

# perform the handshake assuming it's a websocket request
websocket_handshake(request,client) = begin

  key = get_websocket_key(request)
  resp_key = generate_websocket_key(key)

  #TODO: use a proper HTTP response type
  response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: "
  Base.write(client.sock,"$response$resp_key\r\n\r\n")
end

# Implement the WebSocketInterface
# so that this implementation can be used
# in Http's server implementation.
immutable WebSocketHandler <: HttpServer.WebSocketInterface
    handle::Function
end

import HttpServer: handle, is_websocket_handshake
function handle(handler::WebSocketHandler, req::Request, client::HttpServer.Client)
    websocket_handshake(req, client)
    handler.handle(req, WebSocket(client.id, client.sock))
end
function is_websocket_handshake(handler::WebSocketHandler, req::Request)
    get(req.headers, "Upgrade", false) == "websocket"
end

end # module WebSockets
