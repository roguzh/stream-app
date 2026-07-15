const express = require('express');
const http = require('http');
const os = require('os');
const { Server } = require('socket.io');

const app = express();
const server = http.createServer(app);
const io = new Server(server);

const PORT = process.env.PORT || 3000;
const ROOM = 'stream';

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

io.on('connection', (socket) => {
  console.log(`[${timestamp()}] Client connected: ${socket.id}`);

  socket.on('join', (room) => {
    socket.join(room || ROOM);
    console.log(`[${timestamp()}] ${socket.id} joined room "${room || ROOM}"`);
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

  socket.on('disconnect', () => {
    console.log(`[${timestamp()}] Client disconnected: ${socket.id}`);
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
  console.log('');
  console.log('Open /sender on Mac/iPhone');
  console.log('Open /receiver on Mi Box');
});
