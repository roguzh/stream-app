const express = require('express');
const http = require('http');
const os = require('os');
const { Server } = require('socket.io');

const app = express();
const server = http.createServer(app);
const io = new Server(server);

const PORT = process.env.PORT || 3000;
const ROOM = 'stream';
const STREAM_PASSWORD = process.env.STREAM_PASSWORD || null;

app.use(express.static(__dirname + '/public'));

app.get('/sender', (req, res) => {
  res.sendFile(__dirname + '/public/sender.html');
});

app.get('/receiver', (req, res) => {
  res.sendFile(__dirname + '/public/receiver.html');
});

function timestamp() {
  return new Date().toISOString();
}

// Only the signaling channel is gated, not the static pages — the app's source is
// public on GitHub either way, so the thing actually worth protecting is who can
// join the WebRTC session (see/inject the stream), not who can load the JS.
if (STREAM_PASSWORD) {
  io.use((socket, next) => {
    if (socket.handshake.auth && socket.handshake.auth.password === STREAM_PASSWORD) {
      return next();
    }
    next(new Error('Incorrect password'));
  });
}

// Tracks the single active sender/receiver socket id per room so a second sender
// or receiver gets a clear rejection instead of silently cross-talking with an
// existing session (two senders both offering, or two receivers both answering,
// breaks the 1:1 RTCPeerConnection on the other end in confusing ways).
const roomState = { [ROOM]: { sender: null, receiver: null } };

io.on('connection', (socket) => {
  console.log(`[${timestamp()}] Client connected: ${socket.id}`);

  socket.on('join', (payload) => {
    const room = (payload && payload.room) || ROOM;
    const role = payload && payload.role;
    const state = roomState[room] || (roomState[room] = { sender: null, receiver: null });

    if (role === 'sender' || role === 'receiver') {
      if (state[role] && state[role] !== socket.id) {
        console.log(`[${timestamp()}] ${socket.id} rejected — ${role} slot already held by ${state[role]}`);
        socket.emit('join-rejected', {
          reason: role === 'sender'
            ? 'Another sender is already streaming to this room.'
            : 'Another receiver is already connected to this room.'
        });
        return;
      }
      state[role] = socket.id;
      socket.data.room = room;
      socket.data.role = role;
    }

    socket.join(room);
    console.log(`[${timestamp()}] ${socket.id} joined room "${room}"${role ? ` as ${role}` : ''}`);
  });

  socket.on('offer', (offer) => {
    socket.to(ROOM).emit('offer', offer);
  });

  socket.on('answer', (answer) => {
    socket.to(ROOM).emit('answer', answer);
  });

  socket.on('ice-candidate', (candidate) => {
    socket.to(ROOM).emit('ice-candidate', candidate);
  });

  socket.on('receiver-quality', (data) => {
    socket.to(ROOM).emit('receiver-quality', data);
  });

  socket.on('disconnect', () => {
    console.log(`[${timestamp()}] Client disconnected: ${socket.id}`);
    const room = socket.data.room;
    const role = socket.data.role;
    if (room && role && roomState[room] && roomState[room][role] === socket.id) {
      roomState[room][role] = null;
    }
    socket.to(ROOM).emit('peer-disconnected');
  });
});

function getLocalIp() {
  const interfaces = os.networkInterfaces();
  const preferredNames = ['en0', 'en1', 'eth0', 'wlan0'];

  for (const name of preferredNames) {
    for (const iface of interfaces[name] || []) {
      if (iface.family === 'IPv4' && !iface.internal) {
        return iface.address;
      }
    }
  }

  for (const name of Object.keys(interfaces)) {
    if (name.startsWith('bridge') || name.startsWith('utun') || name.startsWith('awdl') || name.startsWith('llw')) {
      continue;
    }
    for (const iface of interfaces[name]) {
      if (iface.family === 'IPv4' && !iface.internal) {
        return iface.address;
      }
    }
  }

  return 'localhost';
}

server.listen(PORT, () => {
  const localIp = getLocalIp();
  console.log('Stream app running:');
  console.log(`  Local:   http://localhost:${PORT}`);
  console.log(`  Network: http://${localIp}:${PORT}`);
  console.log(`  Password: ${STREAM_PASSWORD ? 'required' : 'not set (open access)'}`);
  console.log('');
  console.log('Open /sender on Mac/iPhone');
  console.log('Open /receiver on Mi Box');
});
