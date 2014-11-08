worker_processes 4
preload_app true
require 'socket'
listen "/dev/shm/app.sock", backlog: 8192 if Socket.gethostname == "isu26b"
